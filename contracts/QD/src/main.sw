
contract;

use libraries::{
    imports::*,
    Quid
};

use std::{
    auth::msg_sender,
    block::height,
    call_frames::{
        msg_asset_id,
        contract_id,
    },
    context::{
        msg_amount,
        this_balance,
    },
    constants::{
        BASE_ASSET_ID,
        ZERO_B256
    },
    token::transfer,
    storage::storage_vec::*,
};

use signed_integers::i64::I64;
use fixed_point::ufp128::UFP128;
use fixed_point::ifp256::IFP256;


storage {
    addresses: StorageVec<Address> = StorageVec {}, // store addresses once
    pledges: StorageMap<Address, Pledge> = StorageMap {},
    
    sorted_shorts: StorageVec<u64> = StorageVec {}, // instead of twice here
    sorted_longs: StorageVec<u64> = StorageVec {}, // and here...u64 is less space
    // TODO map storing votes by address

    stats: PledgeStats = PledgeStats { // global stats
        long: Stats { val_ether: UFP128::zero(), 
            stress_val: UFP128::zero(), avg_val: UFP128::zero(),
            stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
            premiums: UFP128::zero(), rate: UFP128::zero(),
        }, 
        short: Stats { val_ether: UFP128::zero(), 
            stress_val: UFP128::zero(), avg_val: UFP128::zero(),
            stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
            premiums: UFP128::zero(), rate: UFP128::zero(),
        }, 
        val_ether_sp: UFP128::zero(), 
        val_total_sp: UFP128::zero(),
    },
    live: Pool = Pool { // Active borrower assets
        long: Pod { credit: 0, debit: 0, }, // ETH, QD
        short: Pod { credit: 0, debit: 0, }, // QD, ETH
    },
    deep: Pool = Pool { // Defaulted borrower assets
        long: Pod { credit: 0, debit: 0, }, // QD, ETH
        short: Pod { credit: 0, debit: 0, }, // ETH, QD
    },
    // TODO make it pool instead, long is in SP
    // short is in LP, because Sinners bring
    // external liquidity in to pay for APR.
    // they also bear losses first from DP...
    blood: Pod = Pod { // Solvency Pool deposits 
        credit: 0, // QD
        debit: 0 // ETH
    },
    crank: Crank = Crank { done: true, // used for updating pledges 
        index: 0, last_update: 0, price: ONE, // eth price in usd / qd per usd
        vol: ONE, last_oracle: 0, // timestamp of last oracle update, for assert
        target: 137, // https://science.howstuffworks.com/dictionary/physics-terms/why-is-137-most-magical-number.htm
        scale: ONE,
        sum_w_k: 0, k: 0, // used for weighted median rebalancer
        // TODO we need a separate target, scale, etc. ^ for long and short
        // TODO in the future aggregate these into one? 
    },
    // the following used for weighted median voting
    target_weights: StorageVec<u64> = StorageVec {}, 
    // TODO make copy for short 
}

/**
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

        redeem(qd_to_buy);
    }
    
    // Liquid ETH value in QD
    // = (FinalDebt + Net) * (1 - 1.10 / (Net / FinalDebt + 1))
    // Net = liquid QD + initial QD collat - initial ETH debt in QD                  
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
*/

/**  Weighted Median Algorithm for Solvency Target Voting
 *  Find value of k in range(1, len(Weights)) such that 
 *  sum(Weights[0:k]) = sum(Weights[k:len(Weights)+1])
 *  = sum(Weights) / 2
 *  If there is no such value of k, there must be a value of k 
 *  in the same range range(1, len(Weights)) such that 
 *  sum(Weights[0:k]) > sum(Weights) / 2
*/

#[storage(read, write)] fn weights_init() {
    let mut i = 0; 
    // let mut n = 125; 
    while i < 21 { // 21 elements total
        storage.target_weights.push(0);
        // n += 5;
        i += 1;
    }
    // assert(n == 225)
}

#[storage(read, write)] fn rebalance(new_stake: u64, new_vote: u64, 
                                     old_stake: u64, old_vote: u64) { // TODO long or short
    
    require(new_vote >= 125 && new_vote <= 225 
    && new_vote % 5 == 0, VoteError::BadVote);
    if storage.target_weights.len() != 20 { // only executes once
        weights_init();
    }
    let mut crank = storage.crank.read();
    let mut median = crank.target;

    let stats = storage.stats.read();
    let total = stats.val_total_sp.value.as_u64().unwrap();
    let mid_stake = total / 2;

    if old_vote != 0 && old_stake != 0 {
        let old_index = (old_vote - 125) / 5;
        storage.target_weights.set(old_index,
            storage.target_weights.get(old_index).unwrap().read() - old_stake
        );
        if old_vote <= median {   
            crank.sum_w_k -= old_stake;
        }
    }
    let index = (new_vote - 125) / 5;
    if new_stake != 0 {
         storage.target_weights.set(index,
            storage.target_weights.get(index).unwrap().read() + new_stake
        );
    }
    if new_vote <= median {
        crank.sum_w_k += new_stake;
    }		  
    if total != 0 && mid_stake != 0 {
        if median > new_vote {
            while crank.k >= 1 && ((crank.sum_w_k - storage.target_weights.get(crank.k).unwrap().read()) >= mid_stake) {
                crank.sum_w_k -= storage.target_weights.get(crank.k).unwrap().read();
                crank.k -= 1;			
            }
        } else {
            while crank.sum_w_k < mid_stake {
                crank.k += 1;
                crank.sum_w_k += storage.target_weights.get(crank.k).unwrap().read();
            }
        }
        median = (crank.k * 5) + 125; // convert index to target
        
        // TODO can sometimes be a number not divisible by 5, probably fine
        if crank.sum_w_k == mid_stake { 
            let intermedian = median + ((crank.k + 1) * 5) + 125;
            median = intermedian / 2;
        }
        crank.target = median;
    }  else {
        crank.sum_w_k = 0;
    }
    storage.crank.write(crank);
}

#[storage(read, write)] fn fetch_pledge(owner: Address, create: bool, sync: bool) -> Pledge {
    let key = storage.pledges.get(owner);
    let mut pledge = Pledge {
        live: Pool {
            long: Pod { credit: 0, debit: 0 },
            short: Pod { credit: 0, debit: 0 },
        },
        stats: PledgeStats {                
            long: Stats { val_ether: UFP128::zero(), 
                stress_val: UFP128::zero(), avg_val: UFP128::zero(),
                stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
                premiums: UFP128::zero(), rate: UFP128::zero(),
            }, 
            short: Stats { val_ether: UFP128::zero(), 
                stress_val: UFP128::zero(), avg_val: UFP128::zero(),
                stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
                premiums: UFP128::zero(), rate: UFP128::zero(),
            }, 
            val_ether_sp: UFP128::zero(), 
            val_total_sp: UFP128::zero(),
        }, ether: 0, quid: 0,
       index: storage.addresses.len(),
    };
    if key.try_read().is_none() {
        if create {
            storage.addresses.push(owner);
            return pledge;
        } else {
            revert(420);
        }
    } else {
        pledge = key.read();
        let crank = storage.crank.read(); // get this object from caller
        // pass it along to try_kill to save gas on reads TODO
        let mut long_touched = false;
        let mut short_touched = false;
        
        // Should it trigger auto-redeem / short save 1.1 CR ?
        // short_save from lick

        if sync {
            let mut cr = calc_cr(crank.price, pledge.live.long.credit, pledge.live.long.debit, false);
            // if dual flip options instead of liquidating, charge 16%, take 1% of profits
            // TODO if paying 4-8% throw long into short
            // else if 16 it's automated the whole time 
            // else only pay .05% month protected upfront
            
            if cr > 0 && cr < ONE {
                /**
                let nums = try_kill(owner, 
                    Pod { credit: pledge.quid, debit: pledge.ether }, 
                    Pod { credit: pledge.live.long.credit, debit: pledge.live.long.debit }, 
                    false, crank.price
                );
                pledge.live.long.credit = nums.1;
                pledge.live.long.debit = nums.3;
                pledge.ether = nums.0;
                pledge.quid = nums.2;
                long_touched = true;    
                */
            }
            cr = calc_cr(crank.price, pledge.live.short.credit, pledge.live.short.debit, true);
            if cr > 0 && cr < ONE {
                // TODO liquidate short
                /**
                let nums = try_kill(owner,
                    Pod { credit: pledge.quid, debit: pledge.eth }, 
                    Pod { credit: pledge.live.short.credit, debit: pledge.live.short.debit },
                    true, crank.price
                );
                pledge.live.short.credit = nums.1;
                pledge.live.short.debit = nums.3;
                pledge.quid = nums.0;
                pledge.ether = nums.2;
                short_touched = true;
                */
            }
            // TODO this will remove the pledge if it finds zeroes
            // storage.save_pledge(&id, &mut pledge, long_touched, short_touched);
            // storage.pledges.insert(who, pledge); 
        }
        return pledge;
    }
}


#[storage(read, write)] fn stress_pledge(owner: Address) { 
    
    let mut stats = storage.stats.read();
    let mut live = storage.live.read();
    let mut deep = storage.deep.read();
    let crank = storage.crank.read();

    let mut p: Pledge = fetch_pledge(owner, false, false);
    
    require(crank.price > ONE, PriceError::NotInitialized);
    require(crank.vol > ONE, PriceError::NotInitialized);
    
    let mut vol = UFP128::from_uint(crank.vol); // get annualized volatility of ETH
    let price = UFP128::from_uint(crank.price);
    
    let one = IFP256::from(UFP128::from_uint(ONE));
    let mut neg_one = one;
    neg_one = neg_one.sign_reverse();

    let mut short_touched = false;
    let mut long_touched = false;
    let mut due = 0;         
    
    // TODO check precision stuff
    // will be sum of each borrowed crypto amt * its price
    p.stats.short.val_ether = price * UFP128::from_uint(p.live.short.debit) / UFP128::from_uint(ONE); 
    
    let mut val_ether = p.stats.short.val_ether;
    let mut qd = UFP128::from_uint(p.live.short.credit); // surety

    if val_ether > UFP128::zero() { // $ value of Pledge ETH debt
        short_touched = true;
        let eth = IFP256::from(val_ether);
        // let mut iW = eth; // the amount of this crypto in the user's short debt portfolio, times the crypto's price
        // iW /= eth; // 1.0 for now...TODO later each crypto will carry a different weight in the portfolio, i.e. divide each iW by total $val 
        // let var = (iW * iW) * (vol * vol); // aggregate for all Pledge's crypto debt
        // let mut ivol = var.sqrt(); // portfolio volatility of the Pledge's borrowed crypto
        let scale = UFP128::from_uint(crank.scale);
        let QD = IFP256::from(qd);

        // $ value of borrowed crypto in upward price shocks of avg & bad magnitudes
        let mut pct = stress(true, vol, true);
        let avg_val = (one + pct) * eth;
        pct = stress(false, vol, true);

        let stress_val = (one + pct) * eth;
        let mut stress_loss = stress_val - QD; // stressed value

        if stress_loss < IFP256::zero() { // TODO this doesn't make sense check cpp
            stress_loss = IFP256::zero(); // better if this is zero, if it's not 
            // that means liquidation (debt value worth > QD collat)
        } 
        let mut avg_loss = avg_val - QD;
        // stats.short.stress_loss += stress_loss; 
        p.stats.short.stress_loss = stress_loss.underlying;
        // stats.short.avg_loss += avg_loss; 
        p.stats.short.avg_loss = avg_loss.underlying;

        // market determined implied volaility
        vol *= scale;
        // TODO should scale also be applied before `stress` call above?
        let delta = pct + one;
        let l_n = IFP256::from(ln(delta.underlying) * scale); // * calibrate
        let i_stress = IFP256::exp(l_n) - one; // this might be negative
        
        let mut payoff = eth * (one + i_stress);
        if payoff > QD {
            payoff -= QD;
        } else {
            payoff = IFP256::zero();
        };
        p.stats.short.rate = pricing(payoff.underlying, 
            scale, eth.underlying, 
            QD.underlying, vol, true
        );
        p.stats.short.premiums = p.stats.short.rate * val_ether;
        stats.short.premiums += p.stats.short.premiums;
        due = (p.stats.short.premiums / UFP128::from_uint(PERIOD)).value.as_u64().unwrap();
        // TODO uncomment above, options pricing
        // this is a placeholder just for testing
        // due = 5% x scale
        
        p.live.short.credit -= due; // the user pays their due by losing a bit of QD collateral
        live.short.credit -= due; // reduce QD collateral in the LivePool
            
        // pay SolvencyProviders by reducing how much they're owed to absorb in QD debt
        if deep.long.credit > due { 
            deep.long.credit -= due;
        } else { // take the remainder and add it to QD collateral to be absorbed from DeadPool
            due -= deep.long.credit;
            deep.long.credit = 0;
            deep.short.debit += due;
        }     
    }     
    
    // TODO unsafe
    p.stats.long.val_ether = price * UFP128::from_uint(p.live.long.credit) / UFP128::from_uint(ONE); // will be sum of each crypto collateral amt * its price
    val_ether = p.stats.long.val_ether;
    qd = UFP128::from_uint(p.live.long.debit); // debt
    
    if val_ether > UFP128::zero() {
        // let mut iW = val_ether; // the amount of this crypto in the user's long collateral portfolio, times the crypto's price
        // iW /= val_ether; // 1.0 for now...TODO later each crypto will carry a different weight in the portfolio
        // let var = (iW * iW) * (iVvol * iVvol); // aggregate for all Pledge's crypto collateral
        // let mut vol = var.sqrt(); // total portfolio volatility of the Pledge's crypto collateral
        long_touched = true;

        let scale = UFP128::from_uint(crank.scale); // TODO crank.long.scale
        let eth = IFP256::from(val_ether);
        let QD = IFP256::from(qd);

        // $ value of crypto collateral in downward price shocks of bad & avg magnitudes
        let mut pct = stress(true, vol, false); // TODO assert that pct is within the same precision as one = 100%
        let avg_val = (one - pct) * eth;
        
        pct = stress(false, vol, false);
        // model suggested $ value of surety in high stress
        let stress_val = (one - pct) * eth;
        
        // model suggested $ amount of insufficient surety 
        let mut stress_loss = QD - stress_val;
        if stress_loss < IFP256::zero() {   
            stress_loss = IFP256::zero();  
        }
        let mut avg_loss = QD - avg_val;
        if avg_loss < IFP256::zero() { 
            // TODO raise assertion?
            avg_loss = IFP256::zero();   
        }

        // stats.long.stress_loss += stress_loss; 
        p.stats.long.stress_loss = stress_loss.underlying;
        // stats.long.avg_loss += avg_loss; 
        p.stats.long.avg_loss = avg_loss.underlying;
        
        // TODO self.data_l.scale;
        vol *= scale; // market determined implied volaility
        let delta = (neg_one * pct) + one; // using high stress pct
        let l_n = IFP256::from(ln(delta.underlying) * scale); // * calibrate
        let i_stress = neg_one * (IFP256::exp(l_n) - one);
        let mut payoff = eth * (one - i_stress);
        if payoff > QD {
            payoff = IFP256::zero();
        } else {
            payoff = IFP256::from(
                UFP128::from_uint(p.live.long.debit)
            ) - payoff;
        };
        // TODO crank.short.scale 
        p.stats.long.rate = pricing(payoff.underlying, 
            scale, val_ether, QD.underlying, vol, false
        );
        p.stats.long.premiums = p.stats.long.rate * QD.underlying;
        
        stats.long.premiums += p.stats.long.premiums;
        due = (p.stats.short.premiums / UFP128::from_uint(PERIOD)).value.as_u64().unwrap();

        let mut due_in_ether = ratio(ONE, crank.price, due);
        // Debit Pledge's long side for duration
        // (it's credited with ether on creation)
        p.live.long.credit -= due_in_ether; 
        live.long.credit -= due_in_ether;
    
        // pay SolvencyProviders by reducing how much they're owed to absorb in ether debt
        if deep.short.credit > due_in_ether { 
            deep.short.credit -= due_in_ether;
        } else { // take the remainder and add it to ether collateral to be absorbed from DeadPool
            due_in_ether -= deep.short.credit;
            deep.short.credit = 0;
            deep.long.debit += due_in_ether;
        }  
    }
    
    // TODO save crank, deep pool, live pool
    // self.save_pledge(&id, &mut p, long_touched, short_touched);
}

impl Quid for Contract 
{    
    // Close out caller's borrowing position by paying
    // off all pledge's own debt with own collateral
    #[storage(read, write)] fn fold(short: bool) { 
        // TODO take an amount, if amount is zero
        // then fold the whole pledge
        // otherwise shrink by amount

        let mut blood = storage.blood.read();
        let crank = storage.crank.read();
        require(crank.price > 0, PriceError::NotInitialized);

        let sender = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(sender, false, true);
        
        if short { 
            let eth = pledge.live.short.debit;
            // this is how much QD surety we are returning to SP from LP
            let qd = ratio(crank.price, eth, ONE); 
            // TODO instead of decrementing from DP
            // write how much is being debited against DP
            // assert that this never exceeds DP balance
            // as such, while payments are being made out 
            // of DP into SP...maintain invariant that 
            // when SP withdraws 
            redeem(qd); // assume this QD comes from surety,
            // which we actually burn off in the next function
            // TODO 
            // possible bug ETH can leave SP
                // paydown the debt in the pledge
                // but that ETH stays in the contract
                // and it is no longer available to SP withdrawl?
            turn(eth, true, sender); // reduce ETH debt
            // send ETH back to SP since it was borrowed from
            // there in the first place...but since we redeemed
            // the QD that was surety, we were able to clear some
            // long liquidatons along the way, destroying debt
            // blood.debit += 
        } else { // TODO all the same logic as above applies in shrink
            let eth = ratio(ONE, pledge.live.long.debit, crank.price);
            invert(eth);
             // TODO dont go into deep first go into SP
            // if SP wants to withdraw, QD value only
            // DP coll goes into SP, debt goes into LP
            // verify with borrow function 
            turn(pledge.live.long.debit, false, sender);
        }   
    }

    // TODO save current stake as old_stake local var, set new stake
    // update totals, rebalance for long if long, short if short
    // - deposit with insurance (pay by absorbing licks) or without
    // - get paid premiums from shorts and longs, you can retrieve
    // - gains, but prinicipal is time-locked, no price insurance
    #[payable]
    #[storage(read, write)] fn deposit(live: bool, long: bool) 
    {
        let sender = get_msg_sender_address_or_panic();
        let mut amt = msg_amount();
        require(amt > ONE, AssetError::BelowMinimum); // TODO 1000
        let mut pledge = fetch_pledge(sender, true, true);

        if msg_asset_id() == contract_id().into() { // QD
            if live { // adding surety to borrowing
                let mut pool = storage.live.read(); 
                if long { 
                    if pledge.live.long.debit > 0 { // try pay down debt
                        let qd = min(pledge.live.long.debit, amt);
                        pledge.live.long.debit -= qd;
                        amt -= qd;
                        // TODO should we burn QD from the supply?
                    }
                    if amt > 0 { // TODO
                        // redeem remaining QD 
                        // deposit ETH suretty 
                    }
                }
                else { pledge.live.short.credit += amt;
                    pool.short.credit += amt;
                    storage.live.write(pool);
                }
            } else { pledge.quid += amt;
                let mut pod = storage.blood.read();
                pod.credit += amt;
                storage.blood.write(pod);   
            }
        } 
        else if msg_asset_id() == BASE_ASSET_ID { // ETH
            if live { 
                let mut pool = storage.live.read(); 
                if long { pledge.live.long.credit += amt;
                    pool.long.credit += amt;
                    storage.live.write(pool);
                } 
                else { 
                    if pledge.live.short.debit > 0 {
                        let eth = min(pledge.live.short.debit, amt);
                        pledge.live.short.debit -= eth;
                        amt -= eth;
                        // TODO we can't burn the ETH for paying down the
                        // debt, so what do we do with it? 
                    }
                    if amt > 0 { // TODO
                        // invert remaining ETH
                        // deposit QD surety
                    }   
                }
            }
            else { pledge.ether += amt;
                let mut pod = storage.blood.read();
                pod.debit += amt;
                storage.blood.write(pod);
            }
        }
        storage.pledges.insert(sender, pledge); // TODO save_pledge
    }


    /* Function exists to allow withdrawal of LP and SP deposits, 
     * from LP back into SP or out. From SP, only QD (selling to DP)
     * a user's SolvencyPool deposit, or LivePool (borrowing) position.
     * Thus, the first boolean parameter's for indicating which pool,
     * & last boolean parameter indicates currency being withdrawn. 
     */
    // TODO set old stake to current stake, 
    // at the end update global total, delta since 
    // if withdraw with msg_amount > 0, it's a borrow 
    // which uses the valve function if the QD < 10x
    #[storage(read, write)] fn withdraw(amt: u64, qd: bool, sp: bool) 
    {    
        let crank = storage.crank.read();
        require(crank.price > ONE, PriceError::NotInitialized);
        require(amt > 0, AssetError::BelowMinimum);
        
        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, false, true);
        // TODO if withdrawal out from SP and not into it
        // sync must be true because what if timing withdrawl
        // right before liquidation, takes in % of losses owed
        // as a % of the deposit being withdrawn. 
        
        let mut least: u64 = 0; 
        let mut cr: u64 = 0; 

        if !qd {
            if !sp {
                let mut pool = storage.live.read(); // Pay withdraw fee
                least = min(pledge.live.long.credit, (amt + amt/100));
                pledge.live.long.credit -= least;
                
                cr = calc_cr(crank.price, pledge.live.long.credit, pledge.live.long.debit, false);    
                require(cr >= MIN_CR, ErrorCR::BelowMinimum);
                
                pool.long.credit -= least;
                storage.live.write(pool);
            } 
            else {
                let mut pod = storage.blood.read();
                least = min(pledge.ether, amt); 
                pledge.ether -= least;
                pod.debit -= least;
                storage.blood.write(pod);
            }
            transfer(Identity::Address(account), BASE_ASSET_ID, least);
        } 
        else {
            require(amt > ONE, AssetError::BelowMinimum);
            if !sp {
                let mut pool = storage.live.read();                
                least = min(pledge.live.short.credit, amt);
                pledge.live.short.credit -= least;
                
                cr = calc_cr(crank.price, pledge.live.short.credit, pledge.live.short.debit, true);
                require(cr >= MIN_CR, ErrorCR::BelowMinimum);
                            
                pool.short.credit -= least;
                storage.live.write(pool);
            }
            else {
                let mut pod = storage.blood.read();
                least = min(pledge.quid, amt); 
                pledge.quid -= least;
                pod.credit -= least;
                storage.blood.write(pod);
            }
            transfer(Identity::Address(account), contract_id().into(), least);
        }
        storage.pledges.insert(account, pledge); 
    }
}

#[storage(read, write)] fn turn(amt: u64, short: bool, sender: Address) -> u64 {
    let mut least: u64 = 0;
    let mut pledge = fetch_pledge(sender, false, false);
    let mut pool = storage.live.read();
    let crank = storage.crank.read();
    require(crank.price > ONE, PriceError::NotInitialized);
    
    if !short { // clear QD debt in long
        least = min(pledge.live.long.debit, amt); 
        if least > 0 { 
            pledge.live.long.debit -= least;
            pool.long.debit -= least;

            let redempt = ratio(ONE, least, crank.price); // get ETH
            pledge.live.long.credit -= redempt; 
            pool.long.credit -= redempt;
        }
    } 
    else { // clear ETH amt of debt in short
        least = min(pledge.live.short.debit, amt);
        if least > 0 {
            pledge.live.short.debit -= least;
            pool.short.debit -= least;

            let redempt = ratio(crank.price, least, ONE); // get QD
            pledge.live.short.credit -= redempt; 
            pool.short.credit -= redempt;            
        }
    }   
    storage.live.write(pool);
    storage.pledges.insert(sender, pledge);
    return least; // how much was redeemed, used for total tallying in turnFrom 
}

#[storage(read, write)] fn redeem(quid: u64) {
    let mut bought: u64 = 0; // ETH collateral to be released from deepPool's long portion
    let mut redempt: u64 = 0; // amount of QD debt being cleared from the DP
    let mut amt = quid; 
    // turnFrom(quid, false, 10); // TODO 10 hardcoded
    if amt > 0 {  // fund redemption by burning against pending DP debt
        let mut deep = storage.deep.read();
        let crank = storage.crank.read();
        require(crank.price > ONE, PriceError::NotInitialized);
        let mut val_ether = ratio(crank.price, deep.long.debit, ONE);
        
        if val_ether > deep.long.credit { // QD in DP worth less than ETH in DP
            val_ether = deep.long.credit; // max QDebt amount that's clearable 
            // otherwise, we can face an edge case where tx throws as a result of
            // not being able to draw equally from both credit and debt of DP
        } if val_ether >= amt { // there is more QD in the DP than amt sold
            redempt = amt; 
            amt = 0; // there will be 0 QD left to clear
        } else {
            redempt = val_ether;
            amt -= redempt; // we'll still have to clear some QD
        }
        if redempt > 0 {
            // paying the deepPool's long side by destroying QDebt
            deep.long.credit -= redempt;
            
            // How much ETH we're about to displace in the deepPool    
            deep.long.debit -= ratio(ONE, redempt, crank.price);
            // TODO maybe instead of taking it from here 
            // aka liquidations that are to be absorbed by SP
            // clear the debt ONLY but take ETH from the SP only...
            // so that the sureties are left to be absorbed
                
            if amt > 0 { // there is remaining QD to redeem after redeeming from deepPool  
                let mut blood = storage.blood.read();
                let mut eth = ratio(ONE, amt, crank.price);
                assert(this_balance(BASE_ASSET_ID) > eth);

                let mut least = min(blood.debit, eth); 
                amt = ratio(crank.price, amt, ONE); // QD paid to SP for ETH sold 
                // storage.token.internal_deposit(&env::current_account_id(), amt); TODO

                blood.credit += amt; // offset, in equal QD value, the ETH sold by SP
                blood.debit -= least; // sub ETH that's getting debited out of the SP
                storage.blood.write(blood);
                
                eth -= least;
                if eth > 0 { // TODO up to a limit  
                    amt = ratio(crank.price, eth, ONE); // in QD
                    // storage.token.internal_deposit(&env::current_account_id(), amt); TODO
                    // DP's QD will get debited (canceling ETH debt) in inversions
                    deep.short.debit += amt;
                    // append defaulted ETH debt to the DP as retroactive settlement
                    deep.short.credit += eth;
                }
            }
            storage.deep.write(deep);
        }
    }
}

// A debit to a liability account means the amount owed is reduced,
// and a credit to a liability account means it's increased. For an 
// income (DP) account, you credit to increase it and debit to decrease,
// 
// expense (DP) account is reversed: gets debited up, and credited down 

// pub(crate) fn invertFrom(quid: u64) {
//     // TODO move turnFrom piece here and let `update` bot handle this using GFund for liquidity
// }

#[storage(read, write)] fn invert(eth: u64) { // inverted air conditions add efficiency to 
    // cash flow
    let mut bought: u64 = 0; // QD collateral to be released from deepPool's short portion
    let mut redempt: u64 = 0; // amount of ETH debt that's been cleared from DP
    // invert against LP, `true` short, 
    // returns ETH remainder to invert
    // gets ETH from most at rist longs 
    let mut amt = eth; // popFrom(eth, true, 10); 
    // TODO up to input hardcoded, 
    //
    if amt > 0 { // there is remaining ETH to be bought 
        let crank = storage.crank.read();
        let mut deep = storage.deep.read(); // for values see Line 54
        // burn debt from DP so it doesn't crystallize next on reprice
        
        // can't clear more ETH debt than is available in the deepPool
        let mut val = min(amt, deep.short.credit); // isn't this QD?

        val = ratio(crank.price, val, ONE); // QD value
        if val > 0 && deep.short.debit >= val { // sufficient QD collateral vs value of ETH sold
            redempt = amt; // amount of ETH credit to be cleared from the deepPool
            bought = val; // amount of QD to debit against short side of deepPool
            amt = 0; // there remains no ETH debt left to clear in the inversion
        } else if deep.short.debit > 0 { // there is less ETH credit to clear than the amount being redeemed
            bought = deep.short.debit; // debit all QD collateral in the deepPool
            redempt = ratio(ONE, bought, crank.price);
            amt -= redempt;
        }
        if redempt > 0 {
            deep.short.credit -= redempt; // ETH Debt
            deep.short.debit -= bought; // QD Collat
        }
        if amt > 0 { // remaining ETH to redeem after clearing against LivePool and deepPool
            let mut blood = storage.blood.read();
            
            let mut quid = ratio(crank.price, amt, ONE);            
            let min_qd = min(quid, blood.credit);
            let min_eth = ratio(ONE, min_qd, crank.price);
            // storage.token.internal_withdraw(&env::current_account_id(), min); TODO
            blood.debit += min_eth;
            blood.credit -= min_qd;
            storage.blood.write(blood);
            
            amt -= min_eth;
            quid -= min_qd;
            
            if quid > 0 { // und das auch 
                // we credit ETH to the long side of the deepPool, which gets debited when redeeming QDebt
                deep.long.debit += amt;
                // append defaulted $QDebt to the deepPool as retroactive settlement to withdraw SPs' $QD
                deep.long.credit += quid; // instead create an order in the order book

                // TODO how come we don't get to print when we do this?
            }
        }
        storage.deep.write(deep);
    }
}

// delight fixture
#[storage(read, write)] fn shrink(credit: u64, debit: u64, short: bool) -> (u64, u64) {
    let mut live = storage.live.read();
    let crank = storage.crank.read();
    require(crank.price > 0, PriceError::NotInitialized);
    /*  Positions with CR below 1 are shit out of luck, but let's say
        105%...it's possible to restore 110 CR by shrinking about half
        Shrinking is atomically selling an amount of collateral and 
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
        debt = ratio(crank.price, debit, ONE);
    } else {
        coll = ratio(crank.price, credit, ONE);
        debt = debit;
    }
    let CR_x_debt = ratio(MIN_CR, debt, ONE);
    let mut delta: u64 = 10;
    delta *= CR_x_debt - coll;
    coll -= delta;
    debt -= delta;
    if short {
        redeem(delta); // sell QD
        live.short.credit -= delta; // decrement QD
        delta = ratio(ONE, delta, crank.price);
        live.short.debit -= delta; // decrement ETH
        debt = ratio(ONE, debt, crank.price);
    } else {
        live.long.debit -= delta; // decrement QD
        delta = ratio(ONE, delta, crank.price);
        invert(delta); // sell ETH
        live.long.credit -= delta; // decrement ETH
        coll = ratio(ONE, coll, crank.price)
    }
    storage.live.write(live);
    return (coll, debt);
}

// allow snatching in both directions
// so 
#[storage(read, write)] fn snatch(db: u64, surety: u64, short: bool) { 
    let crank = storage.crank.read();
    let mut live = storage.live.read();
    let mut deep = storage.deep.read();
    require(crank.price > 0, PriceError::NotInitialized);
    if short { // we are moving crypto debt and QD collateral from LivePool to deepPool
        live.short.credit -= surety; // surety is in QD
        deep.short.credit += surety;
        live.short.debit -= db; // db is in ETH
        
        let val_debt = ratio(crank.price, db, ONE); // get db in QD
        let delta = val_debt - surety; 
        // let delta: I8 = I8::from(db - val_coll);
        assert(delta > 0); // borrower was not supposed to be liquidated
        
        let delta_debt = ratio(ONE, delta, crank.price);
        let debt_minus_delta = db - delta_debt;

        deep.short.debit += debt_minus_delta;

        // clearing delta_debt against 11% tax from sale
    } 
    else { // we are moving QD debt and crypto collateral
        live.long.credit -= surety;
        deep.long.credit += surety;
        live.long.debit -= db;

        let val_coll = ratio(crank.price, surety, ONE);

        let delta: I64 = I64::from(db - val_coll);
        assert(delta > I64::from(0)); // borrower was not supposed to be liquidated
        let db_minus_delta = db - delta.into();

        deep.long.debit += db_minus_delta;

        // clearing delta against 11% tax from sale
    }
}

// blade
// can you blush 
// https://www.youtube.com/watch?v=5kqVgbhenEI

// TODO rewrite to take less parameters cleaner savers
// // TODO find the biggest clip biggest one first, or the lowest CR first if same size 


#[storage(read, write)] fn try_kill(id: Address, SPod: Pod, LPod: Pod, short: bool, price: u64) -> (u64, u64, u64, u64) {
    /* Liquidation protection does an off-setting where deficit margin (delta from min CR)
    in a Pledge can be covered by either its SP deposit, or possibly (TODO) the opposite 
    borrowing position. However, it's rare that a Pledge will borrow both long & short. */

    // TODO if the crypto that is in this LP position came from SP,
    // we must decrease the SP balance accordingly or there will be
    // a double spend when it re-enters the SP from DP...and it will
    // only leave LP to go into DP if saving the pledge didn't work.
    
    let mut nums: (u64, u64, u64, u64) = (0, 0, 0, 0);
    let mut cr: u64 = 0;

    let old_live = storage.live.read();
    let old_blood = storage.blood.read();

    if short {
        nums = short_save(SPod, LPod, price);
        cr = calc_cr(price, nums.1, nums.3, true); // side
        let mut new_live = storage.live.read();
        let mut new_blood = storage.blood.read();
        let mut save = false;
        
        // the result of short_save was...unsuccessful
        if cr < ONE { // fully liquidating the short ^
            // undo asset displacement by short_save |
            // because it wasn't enough to prevent __|
            if SPod.credit > nums.0 { 
                save = true;
                // let delta = SPod.credit - nums.0; 
                new_live.short.credit = old_live.short.credit; // -= delta;
                new_blood.credit = old_blood.credit; // += delta;
            }
            if SPod.debit > nums.2 { // undo SP ETH changes
                save = true;
                // let delta = SPod.debit - nums.2;
                new_live.short.debit = old_live.short.debit; // += delta;
                new_blood.debit = old_blood.debit; // += delta;
            }
            // TODO record the price of liquidation
            // add it to buy-backable collateral (average the price)
            // _end TODO 
            if save {
                storage.live.write(new_live);
                storage.blood.write(new_blood);
            }
            // move liquidated assets from LivePool to deepPool
            snatch(nums.3, nums.1, true);
            // TODO keep debt recorded as negative, this marks that
            // collateral amount may be repurchased at that price
            // like an orderbook for call options. 

            return (SPod.credit, 0, SPod.debit, 0); // zeroed out pledge
        } 
        else if cr < MIN_CR { // TODO can this even work??
            let res = shrink(nums.1, nums.3, true); // handles pool balances
            nums.1 = res.0;
            nums.3 = res.1;
        }
    } 
    else {
        nums = long_save(SPod, LPod, price);
        cr = calc_cr(price, nums.1, nums.3, false);
        let mut new_live = storage.live.read();
        let mut new_blood = storage.blood.read();
        let mut save = false;

        if cr < ONE { // fully liquidating the long side                          
            // undo asset displacement by long_save
            if SPod.debit > nums.0 { // undo SP ETH changes
                // let delta = SPod.debit - nums.0;
                new_live.long.credit = old_live.long.credit; // -= delta; 
                new_blood.debit = old_blood.debit; // += delta;
            }
            if SPod.credit > nums.2 { // undo SP QD changes
                // let delta = SPod.credit - nums.2;
                new_live.long.debit = old_live.long.debit; // += delta; 
                new_blood.credit = old_blood.credit; // += delta;
            }
            // TODO record the price of liquidation
            // add it to sellow-backable collateral (average the price)
            // _end TODO 
            if save {
                storage.live.write(new_live);
                storage.blood.write(new_blood);
            }
            snatch(nums.3, nums.1, false); 
            return (SPod.debit, 0, SPod.credit, 0); // zeroed out pledge
        } 
        else if cr < MIN_CR {
            let res = shrink(nums.1, nums.3, false); // handles pool balances
            // instead, take some QD from DP to payoff the debt, and send e
            nums.1 = res.0;
            nums.3 = res.1;
        }
    }
    return nums;
}

#[storage(read, write)] fn long_save(SPod: Pod, LPod: Pod, price: u64) -> (u64, u64, u64, u64) {
    let crank = storage.crank.read();
    let mut live = storage.live.read();
    let mut blood = storage.blood.read();

    let mut ether = SPod.debit;
    let mut quid = SPod.credit;
    let mut credit = LPod.credit;
    let mut debit = LPod.debit;
    
    // attempt to rescue the Pledge by dipping into its SolvencyPool deposit (if any)
    // try ETH deposit *first*, because long liquidation means ETH is falling, so
    // we want to keep as much QD in the SolvencyPool as we can before touching it 
    /*  How much to increase collateral of long side of pledge, to get CR to 110
        CR = ((coll + x) * price) / debt
        CR * debt / price = coll + x
        x = CR * debt / price - coll
        ^ subtracting the same units
    */ 
    // get distance from CR in units of ETH, debt's value
    // in ETH should be higher than collateral amount 
    let mut delta = ratio(MIN_CR, debit, price) - credit;   
    require(delta > 0, LiquidationError::UnableToLiquidate); 

    let mut least = min(ether, delta);
    if least > 0 { // already covers thee case where there's 0 eth
        delta -= least;
        ether -= least;
        credit += least;
        
        live.long.credit += least; // add LP collat
        blood.debit -= least; // remove eth from SP
    }
    if delta > 0 && quid > 0 { // 
        // recalculate delta in units of QD
        delta -= ratio(price, delta, ONE); 
        
        least = min(quid, delta);
        quid -= least;
        debit -= least;
        
        blood.credit -= least;
        live.long.debit -= least;
    }
    storage.blood.write(blood);
    storage.live.write(live);
    
    return (ether, credit, quid, debit); // we did the best we could, 
    // but there is no guarantee that the CR is back up to MIN_CR
}

#[storage(read, write)] fn short_save(SPod: Pod, LPod: Pod, price: u64) -> (u64, u64, u64, u64) {
    let crank = storage.crank.read();
    let mut live = storage.live.read();
    let mut blood = storage.blood.read();
    
    let mut ether = SPod.debit;
    let mut quid = SPod.credit;
    
    let mut credit = LPod.credit;
    let mut debit = LPod.debit;
    
    // attempt to rescue the Pledge using its SolvencyPool deposit (if any exists)
    // try QD deposit *first*, because short liquidation means ETH is rising, so
    // we want to keep as much ETH in the SolvencyPool as we can before touching it
    let val_debt = ratio(price, debit, ONE); // convert crypto debt to dollars
    // if pledge has ETH in the SP it should stay there b/c it's growing
    // as we know this is what put the short in jeopardy of liquidation
    let final_qd = ratio(MIN_CR, val_debt, ONE); // how much QD we need
    // to be in surety for satisfying the minimum loan collateralisation 

    let mut delta = final_qd - credit; // $ value to add for credit 
    require(delta > 0, LiquidationError::UnableToLiquidate);

    let mut least = min(quid, delta);
    if least > 0 {
        delta -= least;
        quid -= least;
        blood.credit -= least;    

        credit += least;
        live.short.credit += least;
    }
    if delta > 0 && ether > 0 { // delta was not covered fully
        // recalculate delta in units of ETH
        delta = ratio(ONE, delta, price);
        
        least = min(ether, delta);
        ether -= least;
        debit -= least;

        blood.debit -= least;
        live.short.debit -= least;
    }
    storage.blood.write(blood);
    storage.live.write(live);

    return (quid, credit, ether, debit);
}
