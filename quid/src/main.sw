contract;

use std::{
    address::*,
    block::*, // for height()
    assert::*,
    chain::auth::{AuthError, msg_sender},
    hash::sha256,
    identity::Identity,
    logging::log,
    result::Result,
    revert::revert,
    // context::{call_frames::msg_asset_id, msg_amount},
    context::{*, call_frames::*},
    // storage::{StorageMap, StorageVec, get, store},
    storage::*,
    u128::U128,
    contract_id::ContractId,
    token::*,
};

use quid_abi::*;
use helpers::*;

pub const ETH_ID = 0x0000000000000000000000000000000000000000000000000000000000000000; // Token ID of Ether
pub const ONE: u64 = 1_000_000; // 6 digits of precision, same as USDT
// pub const ONE: u64 = 1_000_000_000_000_000_000; // 6 digits of precision, same as USDT
// pub const ONE_ETH: U128 = ~U128::from(0, 1); TODO use 18 digits 
pub const DOT_OH_NINE: u64 = 90_909; 
pub const FEE: u64 = 9_090; // ~ 1%
pub const MIN_CR: u64 =  1_100_000;

storage {
    pledges: StorageMap<Address, Pledge> = StorageMap {},
    balances: StorageMap<Address, u64> = StorageMap {},
    sorted_shorts: StorageVec<Address> = StorageVec {}, 
    sorted_longs: StorageVec<Address> = StorageVec {}, 
    gfund: Pool = Pool { // Guarantee Fund TODO consolidate
        long: Pod { credit: 0, debit: 0, },
        short: Pod { credit: 0, debit: 0, },
    },
    live: Pool = Pool { // Active borrower assets
        long: Pod { credit: 0, debit: 0, },
        short: Pod { credit: 0, debit: 0, },
    },
    deep: Pool = Pool { // Defaulted borrower assets
        long: Pod { credit: 0, debit: 0, },
        short: Pod { credit: 0, debit: 0, },
    },
    brood: Pod = Pod { // Solvency Pool deposits 
        credit: 0, // QD
        debit: 0 // ETH
    },
    crank: Crank = Crank { done: true, 
        index: 0, last: 0
    },
    price: u64 = 1666_000_000, // $1666 // ETH price
    vol: u64 = 200_000
}

// #[storage(read, write)]fn save_pledge(owner: Address) {

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
        if cr < ONE { // we are liquidating this pledge
            // undo asset displacement by short_save
            let now_available: u64 = storage.balances.get(id);
            if available > now_available {
                storage.balances.insert(id, available - now_available);
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
        if cr < ONE {
            // undo asset displacement by long_save
            let now_available: u64 = storage.balances.get(id);
            if available > now_available {
                storage.balances.insert(id, available - now_available);
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

impl Quid for Contract {
    // let h = height();

    // Close out caller's borrowing position by paying
    // off all pledge's own debt with own collateral
    #[storage(read, write)] fn fold(short: bool) { 
        let sender = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(sender, false, true);
        if short {
            let cr = calc_cr(storage.price, pledge.short.credit, pledge.short.debit, true);
            if cr > ONE { // mainly a sanity check, an underwater pledge will almost certainly
                // take QD and sell it for ETH internally in the interest of proper accounting
                let qd = ratio(storage.price, pledge.short.debit, ONE);
                redeem(qd); // https://youtu.be/IYXRSR0xNVc?t=111 pledges will probably
                // be clipped before its owner can fold in time to prevent that from occuring...
                turn( pledge.short.debit, false, true, sender);
            }
        } else {
            let cr = calc_cr(storage.price, pledge.long.credit, pledge.long.debit, false);
            if cr > ONE {
                let eth = ratio(ONE, pledge.long.debit, storage.price);
                invert(eth);
                turn(pledge.long.debit, false, false, sender);
            }
        }   
    }

    // Leon will continuously call this liquidation function on distressed 
    // Pledges. For this reason there is no liquidation fee, because there is an implicit
    // incentive for anyone to run this function, otherwise the peg will be destroyed.
    #[storage(read, write)] fn clap(who: Address) { 
        let mut long_touched = false;
        let mut short_touched = false;
        let mut pledge = fetch_pledge(who, false, false);
        // We don't use fetch_pledge because we'd rather not absorb into
        // a pledge until after they are rescued, to keep their SP balances
        // as high as possible in the interest of rescuing
    
        // TODO clip biggest one first, or the lowest CR first if same size 
        let mut cr = calc_cr(storage.price, pledge.long.credit, pledge.long.debit, false);
        // TODO if the position is in the user defined range, shrink it
        if cr < MIN_CR {
            let nums = try_kill(who, Pod { credit: pledge.quid, debit: pledge.eth }, 
                Pod { credit: pledge.long.credit, debit: pledge.long.debit }, false);

            pledge.long.credit = nums.1;
            pledge.long.debit = nums.3;
            pledge.eth = nums.0;
            pledge.quid = nums.2;
            long_touched = true;
        }
        cr = calc_cr(storage.price, pledge.short.credit, pledge.short.debit, true);
        if cr < MIN_CR {
            let nums = try_kill(who, Pod { credit: pledge.quid, debit: pledge.eth }, 
                Pod { credit: pledge.short.credit, debit: pledge.short.debit }, true);
            
            pledge.short.credit = nums.1;
            pledge.short.debit = nums.3;
            pledge.quid = nums.0;
            pledge.eth = nums.2;
            short_touched = true;
        }
        // storage.save_pledge(&id, &mut pledge, long_touched, short_touched); TODO
        storage.pledges.insert(who, pledge); // TODO save_pledge
    }

    #[storage(read, write)] fn deposit(live: bool, qd_amt: u64, eth_amt: u64) {
        let sender = get_msg_sender_address_or_panic();
        let attached = msg_amount();
        
        assert(qd_amt > 0 || (attached > 0
        && msg_asset_id().into() == ETH_ID));
        
        let mut long_touched = false;
        let mut short_touched = false;
        let mut pledge = fetch_pledge(sender, true, true);

        if live { // adding collateral to borrowing position
            if qd_amt > 0 {  short_touched = true; // QD collateral
                let available = storage.balances.get(sender);
                let mut min = mini(available, qd_amt);
                let mut deposited = min;

                storage.balances.insert(sender, available - min);
                if qd_amt > min { // liquid balance not sufficient, try draw from SP
                    min = mini(pledge.quid, qd_amt - min);
                    deposited += min;
                    pledge.quid -= min;
                }
                storage.live.short.credit += deposited;
                pledge.short.credit += deposited;
            } 
            if eth_amt > 0 { long_touched = true; // ETH collateral 
                storage.live.long.credit += attached;
                pledge.long.credit += attached;
                if eth_amt > attached {
                    let min = mini(pledge.eth, eth_amt - attached);
                    pledge.eth -= min;
                    storage.live.long.credit += min;
                    pledge.long.credit += min;
                }
            }
        } 
        else { // adding deposit to user's SolvencyPool position
            if qd_amt > 0 { // liquid QD into SP
                storage.balances.insert(sender, 
                    storage.balances.get(sender) - qd_amt
                );
                pledge.quid += qd_amt;
            }
            if attached > 0 {
                pledge.eth += attached;
                storage.brood.debit += attached; // ETH can be lent out as a debit to SP
            }
        }
        storage.pledges.insert(sender, pledge); // TODO save_pledge
    }
     
    #[storage(read, write)] fn send(receiver: Address, amount: u64) {
        let sender = get_msg_sender_address_or_panic();
        // Reduce the balance of sender
        let sender_amount = storage.balances.get(sender);
        assert(sender_amount >= amount);
        storage.balances.insert(sender, sender_amount - amount);

        // Increase the balance of receiver
        storage.balances.insert(receiver, storage.balances.get(receiver) + amount);

        log(Sent {
            from: sender, to: receiver, amount: amount
        });
    }

    #[storage(read, write)] fn borrow(amt: u64, short: bool) { 
        let mut cr: u64 = 0;
        let deposit = msg_amount();
        assert(storage.crank.done);
        if deposit > 0 {
            assert(msg_asset_id().into() == ETH_ID);
        }
        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, true, true);

        if !short {
            cr = calc_cr(storage.price, pledge.long.credit, pledge.long.debit, false);
            assert(cr == 0 || cr >= MIN_CR); // 0 if there's no debt yet
            if deposit >= ONE {
                pledge.long.credit += deposit;
                storage.live.long.credit += deposit;
            }
            let new_debt = pledge.long.debit + amt;
            assert(new_debt >= (ONE * 1000));
            
            cr = calc_cr(storage.price, pledge.long.credit, new_debt, false);
            if cr >= MIN_CR { // requested amount to borrow is within measure of collateral
                storage.balances.insert(account, 
                    storage.balances.get(account) + amt
                );
                // TODO pull from GFund (or in mint)
                pledge.long.debit = new_debt;
            } 
            else { // instead of throwing a "below MIN_CR" error right away, try to satisfy loan
                pledge.long = valve(account, false, new_debt, pledge.long); 
            }
        } else { // borrowing short
            if deposit > 0 { /* if they dont have QD and they send in ETH, 
                we can just immediately invert it and use that as coll */
                invert(deposit); // QD value of the ETH debt being cleared 
                pledge.short.credit += ratio(storage.price, deposit, ONE); // QD value of the ETH deposit
            }
            cr = calc_cr(storage.price, pledge.short.credit, pledge.short.debit, true);
            assert(cr == 0 || cr >= MIN_CR); 
            
            let new_debt = pledge.short.debit + amt;

            let new_debt_in_qd = ratio(storage.price, new_debt, ONE);
            assert(new_debt_in_qd >= (ONE * 1000));
            
            cr = ratio(ONE, pledge.short.credit, new_debt_in_qd);
            if cr >= MIN_CR { // when borrowing within their means, we disperse ETH that the borrower can sell
                transfer_to_output(amt, ~ContractId::from(ETH_ID), account); // send ETH to msg.sender
            } else {
                pledge.short = valve(account,true, new_debt_in_qd, pledge.short);
            }
        }
        // self.save_pledge(&account, &mut pledge, !short, short);
        storage.pledges.insert(account, pledge);
    }

     /* This function exists to allow withdrawal of deposits, either from 
     * a user's SolvencyPool deposit, or LivePool (borrowing) position.
     * Thus, the first boolean parameter's for indicating which pool,
     * & last boolean parameter indicates the currency being withdrawn.
    */    
    #[storage(read, write)] fn renege(amt: u64, sp: bool, qd: bool) {
        assert(amt > ONE);
        let mut cr: u64 = 0; 
        let mut min: u64 = 0; 
        let mut do_transfer: bool = false;
        
        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, false, true);
       
        let mut fee = ratio(FEE, amt, ONE);
        let mut amt_sub_fee = amt - fee;
        let gf_cut = fee / 11;
        fee -= gf_cut;

        if !sp { // we are withdrawing collateral from a borrowing position
            if qd {
                storage.live.short.credit -= amt;
                pledge.short.credit -= amt;
                cr = calc_cr(storage.price, pledge.short.credit, pledge.short.debit, true);
                assert(cr >= MIN_CR);
                            
                storage.balances.insert(account, 
                    storage.balances.get(account) + amt_sub_fee
                ); // send QD to the sender
                
                storage.deep.short.debit += fee; // pay fee
                storage.gfund.short.credit += gf_cut;
            }
            else {
                do_transfer = true; // we are sending ETH to the user
                pledge.long.credit -= amt;
                cr = calc_cr(storage.price, pledge.long.credit, pledge.long.debit, false);
                assert(cr >= MIN_CR);
                let eth = storage.live.long.credit;

                if amt_sub_fee > eth { // there's not enough ETH b/c it's been lent out
                    amt_sub_fee = eth;
                    let in_qd = ratio(storage.price, amt_sub_fee - eth, ONE); 
                    storage.balances.insert(account, 
                        storage.balances.get(account) + in_qd
                    ); // mint requested QD to the sender
                    storage.gfund.long.debit += in_qd; // freeze as protocol debt  
                }
                storage.live.long.credit -= amt_sub_fee;
                storage.deep.long.debit += fee;
                storage.gfund.long.credit += gf_cut;
            }   
        } else { // we are withdrawing deposits from the SolvencyPool
            let mut remainder = 0;
            if qd {
                pledge.quid -= amt;
                min = mini(storage.brood.credit, amt); // maximum dispensable QD
                storage.brood.credit -= min;
                remainder = amt - min;
                if remainder > 0 {
                    min = mini(storage.gfund.short.credit, remainder);
                    storage.gfund.short.credit -= min;
                    if remainder > min {
                        remainder -= min;
                        storage.gfund.long.debit += remainder;      
                    }
                }
                // storage.token.internal_withdraw(&env::current_account_id(), amt_sub_fee); 
                storage.balances.insert(account, 
                    storage.balances.get(account) + amt_sub_fee
                ); // send QD to the signer
                storage.deep.short.debit += fee; // pay fee
                storage.gfund.short.credit += gf_cut;
            } else {
                do_transfer = true;
                pledge.eth -= amt;
                min = mini(storage.brood.debit, amt); // maximum dispensable ETH
                storage.brood.debit -= min;
                remainder = amt - min;
                if remainder > 0 {
                    min = mini(storage.gfund.long.credit, remainder); // maximum dispensable ETH
                    storage.gfund.long.credit -= min;
                    if remainder > min {
                        remainder -= min;
                        amt_sub_fee -= remainder;
                        let in_qd = ratio(storage.price, remainder, ONE);
                        storage.balances.insert(account, 
                            storage.balances.get(account) + in_qd
                        ); // mint requested QD
                        storage.gfund.long.debit += in_qd; // freeze as protocol debt  
                    }
                }
                storage.deep.long.debit += fee; // pay fee
                storage.gfund.long.credit += gf_cut;
            }
        }
        storage.pledges.insert(account, pledge);
        // storage.save_pledge(&account, &mut pledge, !sp && !qd, !sp && qd); TODO
        if do_transfer { // workaround for "borrow after move" compile error
            transfer_to_output(amt_sub_fee, ~ContractId::from(ETH_ID), account); // send ETH to msg.sender
        }
    }

    #[storage(read, write)] fn clear(amt: u64, repay: bool, short: bool) {
        let deposit = msg_amount();
        assert(amt > 0 || (deposit > 0
        && msg_asset_id().into() == ETH_ID));

        let account = get_msg_sender_address_or_panic();
        if !repay {
            if short { // ETH ==> QD (short collat), AKA inverting ETH debt
                // TODO if account == richtobacco.eth
                // do invertFrom
                invert(deposit);

                let mut quid = ratio(storage.price, deposit, ONE);        
                let mut fee_amt = ratio(FEE, quid, ONE);
                
                let gf_cut = fee_amt / 11;
                storage.gfund.short.credit += gf_cut;
                    
                quid -= fee_amt;
                fee_amt -= gf_cut;

                storage.deep.short.debit += fee_amt;
                
                storage.balances.insert(account,
                    storage.balances.get(account) + quid
                );
            } 
            else { // QD ==> ETH (long collat), AKA redeeming $QDebt         
                redeem(amt);
        
                storage.balances.insert(account,
                    storage.balances.get(account) - amt
                ); // burn the QD being sold 
                let mut eth = ratio(ONE, amt, storage.price);
                let mut fee_amt = ratio(FEE, eth, ONE);
            
                let gf_cut = fee_amt / 11;
                storage.gfund.long.credit += gf_cut;
                
                eth -= fee_amt;
                fee_amt -= gf_cut;
                
                storage.deep.long.debit += fee_amt;

                transfer_to_output(eth, ~ContractId::from(ETH_ID), account); // send ETH to redeemer
            }    
        } else { // decrement caller's ETH or QDebt without releasing collateral
            if !short { // repay QD debt, distinct from premium payment which does not burn debt but instead distributes payment ?? TODO
                storage.balances.insert(account,
                    storage.balances.get(account) - amt
                ); // burn the QD being paid in as premiums 
                turn(amt, true, false, account);
            }
            else { // repay ETH debt, distinct from premium payment 
                turn(deposit, true, true, account);
            }
        }

    }
    
}

#[storage(read, write)] fn swap(amt: u64, short: bool) -> u64 {
    /// clip everybody in 110 - 111 pro rata, no need to optimize

}

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
            assert(balance_of(~ContractId::from(ETH_ID), contract_id()) > eth);

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
    income account, you credit to increase it and debit to decrease it;
    expense account is reversed: gets debited up, and credited down 
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
// This function uses math to simulate the final result of borrowing, selling borrowed, depositing to borrow more, and repeating
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
