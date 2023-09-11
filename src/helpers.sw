library;

use core::num::*;
use std::{
    address::Address,
    storage::*
    block::*,
    chain::auth::*,
    context::{*, call_frames::*},
    result::*,
    revert::revert,
    identity::Identity,
    u128::U128,
    math::*,
};

pub struct Pod { 
    credit: u64, 
    debit: u64, 
}

pub struct Pool {
    long: Pod, 
    short: Pod,
}

/// Emitted when a token is sent.
pub struct Sent {
    from: Address,
    to: Address,
    amount: u64,
}

pub struct Stats {
    val_eth: u64, // $ value of crypto assets
    stress_val: u64, //  $ value of the Solvency Pool in bad stress 
    avg_val: u64, // $ value of the Solvency Pool in average stress 
    stress_loss: u64, // % loss that Solvency pool would suffer in a bad stress event
    avg_loss: u64, // % loss that Solvency pool would suffer in an avg stress event
    premiums: u64, // $ amount of premiums borrower would pay in a year 
    rate: u64, // annualized rate borrowers pay in periodic premiums 
}

pub struct PledgeStats {
    long: Stats,
    short: Stats,
    val_eth_sp: u64, // $ value of the ETH solvency deposit
    val_total_sp: u64, // total $ value of val_eth + $QD solvency deposit
}

pub struct Pledge { // each User is a Pledge, whether or not borrowing
    // borrowing users will have non-zero values in `long` and `short`
    long: Pod, // debt in $QD, collateral in ETH
    short: Pod, // debt in ETH, collateral in $QD
    stats: PledgeStats, // risk management metrics
    eth: u64, // SolvencyPool deposit of ETH
    quid: u64, // SolvencyPool deposit of $QD
    id: Address,
}

pub struct Crank {
    done: bool, // currently updating
    index: u64, // amount of collateral
    last: u64, // timestamp of last time Crank was updated
}

pub const ONE: u64 = 1_000_000; // 6 digits of precision, same as USDT

pub fn mini(left: u64, right: u64) -> u64 {
    if right > left {
        return right;
    }
    return left;
}

pub fn ratio(multiplier: u64, numerator: u64, denominator: u64) -> u64 { 
    let calculation = (U128::from(0, numerator) * U128::from(0, multiplier));
    let result_wrapped = (calculation / U128::from(0, denominator)).as_u64();

    // TODO remove workaround once https://github.com/FuelLabs/sway/pull/1671 lands.
    match result_wrapped {
        Result::Ok(inner_value) => inner_value, _ => revert(0), 
    }
}

pub fn calc_cr(_price: u64, _collat: u64, _debt: u64, _short: bool) -> u64 {
    if _debt > 0 {
        if _collat > 0 {
            if _short {
                let debt = ratio(_price, _debt, ONE);
                return ratio(ONE, _collat, debt);
            } else {
                return ratio(_price, _collat, _debt);
            }
        }
        else {
            return 0;
        }
    } 
    else if _collat > 0 {
        return u64::max();
    }
    return 0;
}

// Newton's method of integer square root. 
// pub fn integer_sqrt(value: U256) -> U256 {
//     let mut guess: U256 = (value + U256::one()) >> 1;
//     let mut res = value;
//     while guess < res {
//         res = guess;
//         guess = (value / guess + guess) >> 1;
//     }
//     res
// }

pub fn RationalApproximation(t: u64) -> u64 {
    // Abramowitz and Stegun formula 26.2.23.
    // The absolute value of the error should be less than 4.5 e-4.
    let c = [251552, 802853, 10328]; // TODO div by 10^6
    let d = [143279, 189269, 1308]; // TODO ""  "" ""
    t - ((c[2] * t + c[1]) * t + c[0]) / 
        (((d[2] * t + d[1]) * t + d[0]) * t + 1)
}


/// Return the sender as an Address or panic
pub fn get_msg_sender_address_or_panic() -> Address {
    let sender: Result<Identity, AuthError> = msg_sender();
    if let Identity::Address(address) = sender.unwrap() {
       address
    } else {
       revert(0);
    }
}

// #[storage(read, write)] fn swap(amt: u64, short: bool) -> u64 {
    /// clip everybody in 110 - 111 pro rata, no need to optimize
    /// 

// }

#[storage(read, write)] fn turn(amt: u64, repay: bool, short: bool, sender: Address) -> u64 {
    let mut min: u64 = 0;
    let mut pledge = fetch_pledge(sender, false, false);
    if !short { // burn QD up to the pledge's total long debt
        min = mini(pledge.long.debit, amt);
        if min > 0 { // there is any amount of QD debt to burn
            pledge.long.debit -= min;
            storage.live.long.debit -= min;
        }
    } 
    else { // burn ETH debt
        min = mini(pledge.short.debit, amt);
        if min > 0 {
            pledge.short.debit -= min;
            storage.live.short.debit -= min;
        }
    }
    if min > 0 { // the Pledge was touched
        if !repay { 
            if !short { // release ETH collateral, pro quo redeeming debt
                let redempt = ratio(ONE, min, storage.price);
                pledge.long.credit -= redempt;
                storage.live.long.credit -= redempt;
            } 
            else { // release QD collateral...
                // how much QD is `min` worth
                let redempt = ratio(storage.price, min, ONE);
                pledge.short.credit -= redempt;
                storage.live.short.credit -= redempt;
            }
        } 
        // save_pledge(sender, pledge, !short, short); TODO
        storage.pledges.insert(sender, pledge);
    } 
    return min; // how much was redeemed, used for total tallying in turnFrom 
}



#[storage(read, write)] fn redeem(quid: u64) {
    let mut bought: u64 = 0; // ETH collateral to be released from deepPool's long portion
    let mut redempt: u64 = 0; // amount of QD debt being cleared from the DP
    let mut amt = quid; // turnFrom(quid, false, 10); // TODO 10 hardcoded
    if amt > 0 {  // fund redemption by burning against pending DP debt
        let mut val_collat = ratio(storage.price, storage.deep.long.debit, ONE);
        if val_collat > storage.deep.long.credit { // QD in DP worth less than ETH in DP
            val_collat = storage.deep.long.credit; // max QDebt amount that's clearable 
            // otherwise, we can face an edge case where tx throws as a result of
            // not being able to draw equally from both sides of deepPool.long
        } if val_collat >= amt { // there is more QD in the DP than amt sold
            redempt = amt; 
            amt = 0; // there will be 0 QD left to clear
        } else {
            redempt = val_collat;
            amt -= redempt; // we'll still have to clear some QD
        }
        if redempt > 0 {
            // ETH's worth of the QD we're about to displace in the deepPool
            bought = ratio(ONE, redempt, storage.price);
            // paying the deepPool's long side by destroying QDebt
            storage.deep.long.credit -= redempt;
            storage.deep.long.debit -= bought;
        }
        if amt > 0 { // there is remaining QD to redeem after redeeming from deepPool  
            let mut eth = ratio(ONE, amt, storage.price);
            assert(balance_of(BASE_ASSET_ID, contract_id()) > eth);

            let mut min = mini(storage.brood.debit, eth); // maximum ETH dispensable by SolvencyPool
            amt = ratio(storage.price, amt, ONE); // QD paid to SP for ETH sold 
            // storage.token.internal_deposit(&env::current_account_id(), amt); TODO
            storage.brood.credit += amt; // offset, in equal value, the ETH sold by SP
            storage.brood.debit -= min; // sub ETH that's getting debited out of the SP
            
            eth -= min;
            if eth > 0 { // hint, das haben eine kleine lobstah boobie 
                amt = ratio(storage.price, eth, ONE); // in QD
                // storage.token.internal_deposit(&env::current_account_id(), amt); TODO
                // DP's QD will get debited (canceling ETH debt) in inversions
                storage.deep.short.debit += amt;
                // append defaulted ETH debt to the DP as retroactive settlement
                storage.deep.short.credit += eth;
            }
        }
    }
}

/*
    A debit to a liability account means the amount owed is reduced,
    and a credit to a liability account means it's increased. For an 
    income (LP) account, you credit to increase it and debit to decrease it;
    expense (DP) account is reversed: gets debited up, and credited down 
*/
// pub(crate) fn invertFrom(quid: u64) {
//     // TODO move turnFrom piece here and let `update` bot handle this using GFund for liquidity
// }
#[storage(read, write)] fn invert(eth: u64) {
    let mut bought: u64 = 0; // QD collateral to be released from deepPool's short portion
    let mut redempt: u64 = 0; // amount of ETH debt that's been cleared from DP
    // invert against LivePool, `true` for short, returns ETH remainder to invert
    let mut amt = eth; // popFrom(eth, true, 10); // TODO 10 hardcoded
    if amt > 0 { // there is remaining ETH to be bought 
        // can't clear more ETH debt than is available in the deepPool
        let mut val = mini(amt, storage.deep.short.credit);
        val = ratio(storage.price, val, ONE); // QD value
        if val > 0 && storage.deep.short.debit >= val { // sufficient QD collateral vs value of ETH sold
            redempt = amt; // amount of ETH credit to be cleared from the deepPool
            bought = val; // amount of QD to debit against short side of deepPool
            amt = 0; // there remains no ETH debt left to clear in the inversion
        } else if storage.deep.short.debit > 0 { // there is less ETH credit to clear than the amount being redeemed
            bought = storage.deep.short.debit; // debit all QD collateral in the deepPool
            redempt = ratio(ONE, bought, storage.price);
            amt -= redempt;
        }
        if redempt > 0 {
            storage.deep.short.credit -= redempt; // ETH Debt
            storage.deep.short.debit -= bought; // QD Collat
        }
        if amt > 0 { // remaining ETH to redeem after clearing against LivePool and deepPool
            let mut quid = ratio(storage.price, amt, ONE);            
            let min = mini(quid, storage.brood.credit);
            let min_eth = ratio(ONE, min, storage.price);
            // storage.token.internal_withdraw(&env::current_account_id(), min); TODO
            storage.brood.debit += min_eth;
            storage.brood.credit -= min;
            
            amt -= min_eth;
            quid -= min;
            
            if quid > 0 { // und das auch 
                // we credit ETH to the long side of the deepPool, which gets debited when redeeming QDebt
                storage.deep.long.debit += amt;
                // append defaulted $QDebt to the deepPool as retroactive settlement to withdraw SPs' $QD
                storage.deep.long.credit += quid;
                // TODO how come we don't get to print when we do this?
            }
        }
    }
}

// https://twitter.com/1x_Brasil/status/1522663741023731714
// This function uses math to simulate the final result of borrowing, selling borrowed, depositing to borrow more, again...

#[storage(read, write)] fn valve(id: Address, short: bool, new_debt_in_qd: u64, _pledge: Pod) -> Pod {
    let mut pledge = _pledge;
    
    let mut check_zero = false;
    let now_liq_qd: u64 = storage.balances.get(id);
    
    let mut now_coll_in_qd: u64 = 0;
    let mut now_debt_in_qd: u64 = 0;
    
    if short {
        now_debt_in_qd = ratio(storage.price, pledge.debit, ONE);
        now_coll_in_qd = pledge.credit; 
    } else {
        now_coll_in_qd = ratio(storage.price, pledge.credit, ONE);
        now_debt_in_qd = pledge.debit;   
    }
    let mut net_val: u64 = now_liq_qd + now_coll_in_qd - now_debt_in_qd;
    
    // (net_val - (1 - 1 / 1.1 = 0.090909...) * col_init) / 11
    let mut fee_amt: u64 = (net_val - ratio(DOT_OH_NINE, now_coll_in_qd, ONE)) / 11;
    // 11 = 1 + (1 - 1 / 1.1) / fee_% 
    
    let mut qd_to_buy: u64 = fee_amt * 110; // (fee_amt / fee_%) i.e div 0.009090909...
    let mut end_coll_in_qd: u64 = qd_to_buy + now_coll_in_qd;

    let max_debt = ratio(ONE, end_coll_in_qd, MIN_CR);    
    let mut final_debt: u64 = 0;
    
    if new_debt_in_qd >= max_debt {
        final_debt = max_debt;
        check_zero = true;
    } 
    else { // max_debt is larger than the requested debt  
        final_debt = new_debt_in_qd;
        end_coll_in_qd = ratio(MIN_CR, final_debt, ONE);
        
        // no need to mint all this QD, gets partially minted in `redeem`, excluding the
        qd_to_buy = end_coll_in_qd - now_coll_in_qd; // amount cleared against deep pool's QDebt
        fee_amt = ratio(FEE, qd_to_buy, ONE);
    }
    net_val -= fee_amt;
    
    let eleventh = fee_amt / 11;
    let rest = fee_amt - eleventh;

    storage.deep.short.debit += rest;
    storage.gfund.short.credit += eleventh;

    if short {
        pledge.credit = end_coll_in_qd;
        pledge.debit = ratio(ONE, final_debt, storage.price);
        
        storage.live.short.credit += qd_to_buy;
        let eth_to_sell = ratio(ONE, qd_to_buy, storage.price);
        
        // ETH spent on buying QD collateral must be paid back by the borrower to unlock the QD
        storage.live.short.debit += eth_to_sell;
        
        // TODO
        // we must first redeem QD that we mint out of thin air to purchase the ETH, 
        // before burning ETH debt with it to purchase QD (undoing the mint) collat
        redeem(qd_to_buy);
        invert(eth_to_sell);     
    } else {    
        // get final collateral value in ETH
        let end_coll = ratio(ONE, end_coll_in_qd, storage.price);
        
        pledge.credit = end_coll;
        pledge.debit = final_debt;

        let delta_coll = end_coll - pledge.credit;
            
        storage.live.long.credit += delta_coll;
            
        // QD spent on buying ETH collateral must be paid back by the borrower to unlock the ETH
        storage.live.long.debit += qd_to_buy;

        /******/ redeem(qd_to_buy); /******/
    }
    /*
        Liquid ETH value in QD
            = (FinalDebt + Net) * (1 - 1.10 / (Net / FinalDebt + 1))
        Net = liquid QD + initial QD collat - initial ETH debt in QD                  
    */
    let net_div_debt = ratio(ONE, net_val, final_debt) + ONE;

    // `between` must >= 0 as a rule
    let between = ONE - ratio(ONE, MIN_CR, net_div_debt);

    let end_liq_qd = ratio(between, 
        (final_debt + net_val),
    ONE);

    assert(!check_zero || end_liq_qd == 0);
    
    if now_liq_qd > end_liq_qd {
        let to_burn = now_liq_qd - end_liq_qd;
        storage.balances.insert(id, 
            now_liq_qd - to_burn
        );
    } else if end_liq_qd > now_liq_qd {
        let to_mint = end_liq_qd - now_liq_qd;
        storage.balances.insert(id, 
            now_liq_qd + to_mint
        );
    }
    assert(calc_cr(storage.price, pledge.credit, pledge.debit, short) >= MIN_CR); 
    return pledge;
}

// #[storage(read, write)]fn save_pledge(owner: Address) {
    // 
    // 
    // calculate % of total that this pledge absorbed

    // 
    // pay riders
// }

// #[storage(read, write)]fn buy_back(owner: Address) {
//     // when fully liquidated, a borrower's collateral is 
//     // in purgatory.
// }

#[storage(read, write)]fn fetch_pledge(owner: Address, create: bool, sync: bool) -> Pledge {
    let mut pledge = storage.pledges.get(owner);
    let raw_address: b256 = pledge.id.into();
    if raw_address == ETH_ID { // doesn't exist
        if create {
            pledge = Pledge {
                long: Pod { credit: 0, debit: 0 },
                short: Pod { credit: 0, debit: 0 },
                stats: PledgeStats {                
                    long: Stats { val_eth: 0, 
                        stress_val: 0, avg_val: 0,
                        stress_loss: 0, avg_loss: 0,
                        premiums: 0, rate: 0,
                    },
                    short: Stats { val_eth: 0, 
                        stress_val: 0, avg_val: 0,
                        stress_loss: 0, avg_loss: 0,
                        premiums: 0, rate: 0,
                    },
                    val_eth_sp: 0, 
                    val_total_sp: 0,
                },
                eth: 0, quid: 0, id: owner

                // riders
                // { id: % }
            };
        } else {
            revert(0);
        }
    } else {
        if sync {
            // TODO
        }
    }
    return pledge;
}

#[storage(read, write)] fn snatch(debt: u64, collat: u64, short: bool) {
    if short { // we are moving crypto debt and QD collateral from LivePool to deepPool
        storage.live.short.credit -= collat;
        storage.deep.short.credit += collat;
        storage.live.short.debit -= debt;
        
        let val_debt = ratio(storage.price, debt, ONE);
        let delta = val_debt - collat; 
        assert(delta > 0); // borrower was not supposed to be liquidated
        
        let delta_debt = ratio(ONE, delta, storage.price);
        let debt_minus_delta = debt - delta_debt;

        storage.deep.short.debit += debt_minus_delta;
        storage.gfund.short.debit += delta_debt;
    } 
    else { // we are moving QD debt and crypto collateral
        storage.live.long.credit -= collat;
        storage.deep.long.credit += collat;
        storage.live.long.debit -= debt;

        let val_coll = ratio(storage.price, collat, ONE);

        let delta = debt - val_coll;
        assert(delta > 0); // borrower was not supposed to be liquidated
        let debt_minus_delta = debt - delta;

        storage.deep.long.debit += debt_minus_delta;
        storage.gfund.long.debit += delta;
    }
}

#[storage(read, write)] fn shrink(credit: u64, debit: u64, short: bool) -> (u64, u64) {
    /*  Shrinking is atomically selling an amount of collateral and 
        immediately using the exact output of that to reduce debt to
        get its CR up to min. How to calculate amount to be sold:
        CR = (coll - x) / (debt - x)
        CR * debt - CR * x = coll - x
        x(1 - CR) = coll - CR * debt
        x = (CR * debt - coll) * 10
    */
    let mut coll: u64 = 0; // in $
    let mut debt: u64 = 0; // in $
    if short {
        coll = credit;
        debt = ratio(storage.price, debit, ONE);
    } else {
        coll = ratio(storage.price, credit, ONE);
        debt = debit;
    }
    let CR_x_debt = ratio(MIN_CR, debt, ONE);
    let mut delta: u64 = 10;
    delta *= CR_x_debt - coll;
    coll -= delta;
    debt -= delta;
    if short {
        redeem(delta); // sell QD
        storage.live.short.credit -= delta; // decrement QD
        delta = ratio(ONE, delta, storage.price);
        storage.live.short.debit -= delta; // decrement ETH
        debt = ratio(ONE, debt, storage.price);
    } else {
        storage.live.long.debit -= delta; // decrement QD
        delta = ratio(ONE, delta, storage.price);
        invert(delta); // sell ETH
        storage.live.long.credit -= delta; // decrement ETH
        coll = ratio(ONE, coll, storage.price)
    }
    return (coll, debt);
}

#[storage(read, write)] fn try_kill(id: Address, sPod: Pod, lPod: Pod, short: bool) -> (u64, u64, u64, u64) {
    /* Liquidation protection does an off-setting where deficit margin (delta from min CR)
    in a Pledge can be covered by either its SP deposit, or possibly (TODO) the opposite 
    borrowing position. However, it's rare that a Pledge will borrow both long & short. */
    let available: u64 = storage.balances.get(id);
    let mut nums: (u64, u64, u64, u64) = (0, 0, 0, 0);
    let mut cr: u64 = 0;
    if short {
        nums = short_save(id, sPod, lPod, available);
        cr = calc_cr(storage.price, nums.1, nums.3, true);
        if cr < ONE { // fully liquidating the short side
            //                                       ^
            // undo asset displacement by short_save |
            // because it wasn't enough to prevent __|
            let now_available: u64 = storage.balances.get(id);
            if available > now_available {
                storage.balances.insert(id, available);
            }
            if sPod.credit > nums.0 { // undo SP QD changes
                let delta = sPod.credit - nums.0;
                storage.live.short.credit -= delta;
                storage.brood.credit += delta;
            }
            if sPod.debit > nums.2 { // undo SP ETH changes
                let delta = sPod.debit - nums.2;
                storage.live.short.debit += delta;
                storage.brood.debit += delta;
            }
            // TODO record the price of liquidation
            // add it to buy-backable collateral (average the price)
            // _end TODO 

            // move liquidated assets from LivePool to deepPool
            snatch(nums.3, nums.1, true);
            return (sPod.credit, 0, sPod.debit, 0); // zeroed out pledge
        } else if cr < MIN_CR {
            let res = shrink(nums.1, nums.3, true);
            nums.1 = res.0;
            nums.3 = res.1;
        }
    } else {
        nums = long_save(id, sPod, lPod, available);
        cr = calc_cr(storage.price, nums.1, nums.3, false);
        if cr < ONE { // fully liquidating the long side
            //                                      
            // undo asset displacement by long_save
            let now_available: u64 = storage.balances.get(id);
            if available > now_available {
                storage.balances.insert(id, available);
            }
            if sPod.debit > nums.0 { // undo SP ETH changes
                let delta = sPod.debit - nums.0;
                storage.live.long.credit -= delta; 
                storage.brood.debit += delta;
            }
            if sPod.credit > nums.2 { // undo SP QD changes
                let delta = sPod.credit - nums.2;
                storage.live.long.debit += delta; 
                storage.brood.credit += delta;
            }
            // TODO record the price of liquidation
            // add it to sellow-backable collateral (average the price)
            // _end TODO 
            
            snatch(nums.3, nums.1, false); 
            return (sPod.debit, 0, sPod.credit, 0); // zeroed out pledge
        } else if cr < MIN_CR {
            let res = shrink(nums.1, nums.3, false);
            nums.1 = res.0;
            nums.3 = res.1;
        }
    }
    return nums;
}

#[storage(read, write)] fn long_save(id: Address, sPod: Pod, lPod: Pod, available: u64) -> (u64, u64, u64, u64) {
    let mut eth = sPod.debit;
    let mut quid = sPod.credit;
    let mut credit = lPod.credit;
    let mut debit = lPod.debit;
    // attempt to rescue the Pledge by dipping into its SolvencyPool deposit (if any)
    // try ETH deposit *first*, because long liquidation means ETH is falling, so
    // we want to keep as much QD in the SolvencyPool as we can before touching it 
    /*  How much to increase collateral of long side of pledge, to get CR to 110
        CR = ((coll + x) * price) / debt
        CR * debt / price = coll + x
        x = CR * debt / price - coll
        ^ subtracting the same units
    */ 
    let mut delta = ratio(MIN_CR, debit, storage.price) - credit;    
    let mut min = mini(eth, delta);
    
    eth -= min;
    credit += min;
    
    storage.live.long.credit += min;
    storage.brood.debit -= min;

    if delta > min {
        /*  how much to decrease long side's debt
            of pledge, to get its CR up to min
            CR = (coll * price) / (debt - x)
            debt - x = (coll * price) / CR
            x = debt - (coll * price) / CR
            ^ subtracting the same units
        */
        delta -= ratio(storage.price, credit, MIN_CR); // find remaining delta using updated credit
        // first, try to claim liquid QD from user's FungibleToken balance
        min = mini(available, delta);
        delta -= min;
        debit -= min;
        // we only withdraw, but do not deposit because we are burning debt 
        storage.balances.insert(id, available - min);
        storage.live.long.debit -= min;

        if delta > 0 {
            min = mini(quid, delta);
            quid -= min;
            debit -= min;
            
            storage.brood.credit -= min;
            storage.live.long.debit -= min;
        }
    }
    return (eth, credit, quid, debit); // we did the best we could, 
    // but there is no guarantee that the CR is back up to MIN_CR
}

#[storage(read, write)] fn short_save(id: Address, sPod: Pod, lPod: Pod, available: u64) -> (u64, u64, u64, u64) {
    let mut eth = sPod.debit;
    let mut quid = sPod.credit;
    let mut credit = lPod.credit;
    let mut debit = lPod.debit;
    // attempt to rescue the Pledge using its SolvencyPool deposit (if any exists)
    // try QD deposit *first*, because short liquidation means ETH is rising, so
    // we want to keep as much ETH in the SolvencyPool as we can before touching it
    let val_debt = ratio(storage.price, debit, ONE);
    // first, try to claim liquid QD from user's balance
    // if they have ETH in the SP it should stay there b/c it's growing
    // as we know this is what put the short in jeopardy of liquidation
    let final_qd = ratio(MIN_CR, val_debt, ONE);
    let mut delta = final_qd - credit;
    // first, try to claim liquid QD from user's balance
    let mut min = mini(available, delta);
    delta -= min;
    credit += min;
    
    storage.balances.insert(id, available - min);
    // storage.token.internal_deposit(&env::current_account_id(), min); // TODO
    storage.live.short.credit += min;
    
    if delta > 0 {
        min = mini(quid, delta);
        credit += min;
        storage.live.short.credit += min;
        
        delta -= min;
        quid -= min;
        storage.brood.credit -= min;

        if delta > 0 {
            /*  How much to decrease debt of long side of pledge, to get its CR up to min
                CR = coll / (debt * price - x)
                debt * price - x = coll / CR
                x = debt * price - coll / CR
            */
            delta = val_debt - ratio(ONE, credit, MIN_CR);
            
            min = mini(eth, delta);
            eth -= min;
            debit -= min;

            storage.brood.debit -= min;
            storage.live.short.debit -= min;
        }
    }
    return (quid, credit, eth, debit);
}