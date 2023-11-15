
contract;

use libraries::{
    imports::*,
    Quid
};

use std::{
    auth::msg_sender,
    block::timestamp,
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
    token::{
        transfer,
        mint
    },
    storage::storage_vec::*,
};

// use signed_integers::i64::I64;
// use fixed_point::ufp128::UFP128;
// use fixed_point::ifp256::IFP256;

storage { // live deeply, brooder
    pledges: StorageMap<Address, Pledge> = StorageMap {},
    addresses: StorageVec<Address> = StorageVec {}, // store all pledge addresses
    votes: StorageMap<Address, (u64, u64)> = StorageMap {}, // short then long
    stats: PledgeStats = PledgeStats { // global stats
        // TODO uncomment after fixed point compilation error is fixed
        // long: Stats { val_ether: UFP128::zero(), 
        //     stress_val: UFP128::zero(), avg_val: UFP128::zero(),
        //     stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
        //     premiums: UFP128::zero(), rate: UFP128::zero(),
        // }, 
        // short: Stats { val_ether: UFP128::zero(), 
        //     stress_val: UFP128::zero(), avg_val: UFP128::zero(),
        //     stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
        //     premiums: UFP128::zero(), rate: UFP128::zero(),
        // }, 
        // val_ether_sp: UFP128::zero(), 
        // val_total_sp: UFP128::zero(),
        long: Stats { val_ether: 0, 
            stress_val: 0, avg_val: 0,
            stress_loss: 0, avg_loss: 0,
            premiums: 0, rate: 0,
        }, 
        short: Stats { val_ether: 0, 
            stress_val: 0, avg_val: 0,
            stress_loss: 0, avg_loss: 0,
            premiums: 0, rate: 0,
        }, 
        val_ether_sp: 0, 
        val_total_sp: 0,
    },
    live: Pool = Pool { // Active borrower assets
        long: Pod { credit: 0, debit: 0, }, // ETH, QD
        short: Pod { credit: 0, debit: 0, }, // QD, ETH
        // negative balance represents debt after liquidation
        // so now original collateral, which was returned after
        // liquidation continues to be charged unless the debt
        // is relinquished, or sold to a new owner. relinquishing
        // can be forced if there's not enough for SP withdrawals
    },
    deep: Pool = Pool { // Defaulted borrower assets
        long: Pod { credit: 0, debit: 0, }, // QD, ETH
        short: Pod { credit: 0, debit: 0, }, // ETH, QD
    }, 
    
    // negatively charged QD
    // external liquidity in to pay for APR.
    // they also bear losses first from DP...
    brood: Pod = Pod { // Solvency Pool deposits 
        // TODO this starting value should be 0
        // and deposit takes QD that has been 
        // bridged from ERC20 on L1 to Fuel
        // and the same for Ether (gas token)
        credit: 0, // QD 
        debit: 0 // ETH
        // long: Pod, { credit: 0, debit: 0 } // QD, ETH in SP
        // short: Pod, { credit: 0, debit: 0} // QD, ETH in LP
    }, 
    crank: Crank = Crank { 
        last_update: 0, price: ONE, // eth price in usd / qd per usd
        vol: ONE, last_oracle: 0, // timestamp of last oracle update, for assert
        // TODO in the future aggregate these into one? 
        long: Medianizer {
            done: true, index: 0, // used for updating pledges 
            target: 137, // https://science.howstuffworks.com/dictionary/physics-terms/why-is-137-most-magical-number.htm
            scale: ONE,
            sum_w_k: 0, k: 0,
            // solvency: UFP128::zero(),
            solvency: 0,
        },
        short: Medianizer {
            done: true, index: 0, // used for updating pledges 
            target: 137, scale: ONE,
            sum_w_k: 0, k: 0, 
            // solvency: UFP128::zero(),
            solvency: 0,
        }
    },
    // TODO
    // this should be a vector of vectors 
    // length is deterministic, can't number of digits of exceed max debt
    // index 0 represents 1 significant figure, etc
    // the entry at any index is a vector of addresses
    // that are sorted by CR. 
    sorted_longs: StorageVec<Address> = StorageVec {}, 
    long_weights: StorageVec<u64> = StorageVec {},
    short_weights: StorageVec<u64> = StorageVec {},
    sorted_shorts: StorageVec<Address> = StorageVec {},
}

// TODO is this even necessary? Why simulate at all? 
/**  This function is shamelessly dangerous 
It's essentially a flash loan that simulates 
minting QD against a deposit of ETH, selling QD 
for more ETH (against internal protocol liquidity)
to re-deposit and grow a leveraged position...
I don't remember if it's hardcoded for 10x leverage
*/
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

#[storage(read, write)] fn weights_init(short: bool) {
    let mut i = 0; 
    // let mut n = 125; 
    if short {
        if storage.short_weights.len() != 20 { // only executes once
            while i < 21 { // 21 elements total
                storage.short_weights.push(0);
                // n += 5;
                i += 1;
            }
        }
    } else {
        if storage.long_weights.len() != 20 { // only executes once
            while i < 21 { // 21 elements total
                storage.long_weights.push(0);
                // n += 5;
                i += 1;
            }
        }
    }
    // assert(n == 225)
}

/**  Weighted Median Algorithm for Solvency Target Voting
 *  Find value of k in range(1, len(Weights)) such that 
 *  sum(Weights[0:k]) = sum(Weights[k:len(Weights)+1])
 *  = sum(Weights) / 2
 *  If there is no such value of k, there must be a value of k 
 *  in the same range range(1, len(Weights)) such that 
 *  sum(Weights[0:k]) > sum(Weights) / 2
*/

// TODO uncomment after fixed point compilation error is fixed 
/**
#[storage(read, write)] fn rebalance(new_stake: u64, new_vote: u64, 
                                     old_stake: u64, old_vote: u64,
                                     short: bool) { 

    require(new_vote >= 125 && new_vote <= 225 
    && new_vote % 5 == 0, VoteError::BadVote);
    let mut crank = storage.crank.read();

    weights_init(short);
    let mut weights = storage.long_weights;
    let mut data = crank.long;
    if short {
        weights = storage.short_weights;
        data = crank.short;
    }
    let mut median = data.target;

    let stats = storage.stats.read();
    let total = stats.val_total_sp.value.as_u64().unwrap();
    let mid_stake = total / 2;

    if old_vote != 0 && old_stake != 0 {
        let old_index = (old_vote - 125) / 5;
        weights.set(old_index,
            weights.get(old_index).unwrap().read() - old_stake
        );
        if old_vote <= median {   
            data.sum_w_k -= old_stake;
        }
    }
    let index = (new_vote - 125) / 5;
    if new_stake != 0 {
         weights.set(index,
            weights.get(index).unwrap().read() + new_stake
        );
    }
    if new_vote <= median {
        data.sum_w_k += new_stake;
    }		  
    if total != 0 && mid_stake != 0 {
        if median > new_vote {
            while data.k >= 1 && (
                (data.sum_w_k - weights.get(data.k).unwrap().read()) >= mid_stake
            ) {
                data.sum_w_k -= weights.get(data.k).unwrap().read();
                data.k -= 1;			
            }
        } else {
            while data.sum_w_k < mid_stake {
                data.k += 1;
                data.sum_w_k += weights.get(data.k).unwrap().read();
            }
        }
        median = (data.k * 5) + 125; // convert index to target
        
        // TODO can sometimes be a number not divisible by 5, probably fine
        if data.sum_w_k == mid_stake { 
            let intermedian = median + ((data.k + 1) * 5) + 125;
            median = intermedian / 2;
        }
        data.target = median;
    }  else {
        data.sum_w_k = 0;
    }
    if short {
        //storage.short_weights.store_vec(weights);
        crank.short = data;   
    } else {
        //storage.long_weights.store_vec(weights);
        crank.long = data;
    }
    storage.crank.write(crank);
}
*/

#[storage(read, write)] fn save_pledge(account: Address, pledge: Pledge, long_touched: bool, short_touched: bool) {
    let mut dead_short = false;
    let mut dead_long = false;
    if short_touched {
        // TODO uncomment when following TODOs have been solved
        // let returned = storage.sorted_shorts.remove(pledge.index_short);
        // assert(returned.index_short == pledge.index_short);
        // TODO use old values from returned variable and new values from pledge variable
        // to call the rebalance() function
        if pledge.live.short.debit > 0 && pledge.live.short.credit > 0 {
            // TODO helper function
            // this function returns a new index for where in the ordering 
            // this position's reference should be inserted
            
            // let index = helper(pledge_cr);
            
            // TODO insert will move every subsequent element after the position of insertion
            // down by one, but this will not update each Pledge's pointer to their index in the vector
            // this is a problem because the only way to solve it is to iterate through every position again
            // to do something so expensive will make Pledge position updates prohibitively expensive in terms of gas
            
            // storage.sorted_shorts.insert(index, pledge);
        } else {
            dead_short = true;
        }
    }
    if long_touched { // TODO uncomment when above TODOs have been solved
        // let returned = storage.sorted_longs.remove(pledge.index_long);
        // assert(returned.index_long == pledge.index_long);
        // TODO use old values from returned variable and new values from pledge variable
        // to call the rebalance() function
        if pledge.live.long.debit > 0 && pledge.live.long.credit > 0 {
            // storage.sorted_longs.insert(index, pledge);
        } else {
            dead_long = true; 
        }
    }
    if dead_short && dead_long && (pledge.quid == 0)
    &&  (pledge.ether == 0) { storage.pledges.remove(account); }
    else { storage.pledges.insert(account, pledge); }

}

#[storage(read, write)] fn fetch_pledge(owner: Address, create: bool, sync: bool) -> Pledge {
    let key = storage.pledges.get(owner);
    let mut pledge = Pledge {
        live: Pool {
            long: Pod { credit: 0, debit: 0 },
            short: Pod { credit: 0, debit: 0 },
        },
        stats: PledgeStats {       
            // TODO uncomment after fixed point compilation error is fixed         
            // long: Stats { val_ether: UFP128::zero(), 
            //     stress_val: UFP128::zero(), avg_val: UFP128::zero(),
            //     stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
            //     premiums: UFP128::zero(), rate: UFP128::zero(),
            // }, 
            // short: Stats { val_ether: UFP128::zero(), 
            //     stress_val: UFP128::zero(), avg_val: UFP128::zero(),
            //     stress_loss: UFP128::zero(), avg_loss: UFP128::zero(),
            //     premiums: UFP128::zero(), rate: UFP128::zero(),
            // }, 
            // val_ether_sp: UFP128::zero(), 
            // val_total_sp: UFP128::zero(),
            long: Stats { val_ether: 0, 
                stress_val: 0, avg_val: 0,
                stress_loss: 0, avg_loss: 0,
                premiums: 0, rate: 0,
            }, 
            short: Stats { val_ether: 0, 
                stress_val: 0, avg_val: 0,
                stress_loss: 0, avg_loss: 0,
                premiums: 0, rate: 0,
            }, 
            val_ether_sp: 0, 
            val_total_sp: 0,
        }, ether: 0, quid: 0,
       // index_long: 0,
       // index_short: 0,
    };
    if key.try_read().is_none() {
        if create {
            storage.addresses.push(owner);
            return pledge;
        } else {
            revert(42);
        }
    } else {
        pledge = key.read();
        let crank = storage.crank.read(); // get this object from caller
        // pass it along to try_clap to save gas on reads TODO
        let mut long_touched = false;
        let mut short_touched = false;
        
        // Should it trigger auto-redeem / short save 1.1 CR ?
        // short_save from lick

        if sync {
            let mut cr = calc_cr(crank.price, 
                pledge.live.long.credit,
                pledge.live.long.debit,
                false
            ); 
            if cr > 0 && cr < ONE {
                let nums = try_clap(owner, 
                    Pod { 
                        credit: pledge.quid, 
                        debit: pledge.ether 
                    }, 
                    Pod { 
                        credit: pledge.live.long.credit, 
                        debit: pledge.live.long.debit 
                    }, 
                    false, crank.price
                );
                pledge.live.long.credit = nums.1;
                pledge.live.long.debit = nums.3;
                pledge.ether = nums.0;
                pledge.quid = nums.2;
                long_touched = true;    
            }
            cr = calc_cr(crank.price, 
                pledge.live.short.credit, 
                pledge.live.short.debit, 
                true
            );
            if cr > 0 && cr < ONE {
                // TODO liquidate short
                let nums = try_clap(owner,
                    Pod { 
                        credit: pledge.quid, 
                        debit: pledge.ether 
                    }, 
                    Pod { 
                        credit: pledge.live.short.credit, 
                        debit: pledge.live.short.debit 
                    },
                    true, crank.price
                );
                pledge.live.short.credit = nums.1;
                pledge.live.short.debit = nums.3;
                pledge.quid = nums.0;
                pledge.ether = nums.2;
                short_touched = true;
            }
            // TODO massive action regarding take profits from DP based on contribution to solvency

            // TODO this will remove the pledge if it finds zeroes
            // storage.save_pledge(&id, &mut pledge, long_touched, short_touched);
            // storage.pledges.insert(who, pledge); // state is updated before being modified by function call that invoked fetch
        }
        return pledge;
    }
}

/**
#[storage(read, write)] fn stress_short_pledge(owner: Address) { 
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

    let mut touched = false;
    let mut due = 0;         

    // will be sum of each borrowed crypto amt * its price
    // TODO ratio
    p.stats.short.val_ether = price * UFP128::from_uint(p.live.short.debit) / UFP128::from_uint(ONE); 
    
    let val_ether = p.stats.short.val_ether;
    let qd = UFP128::from_uint(p.live.short.credit); // collat

    if val_ether > UFP128::zero() { // $ value of Pledge ETH debt
        touched = true;
        let eth = IFP256::from(val_ether);
        // let mut iW = eth; // the amount of this crypto in the user's short debt portfolio, times the crypto's price
        // iW /= eth; // 1.0 for now...TODO later each crypto will carry a different weight in the portfolio, i.e. divide each iW by total $val 
        // let var = (iW * iW) * (vol * vol); // aggregate for all Pledge's crypto debt
        // let mut ivol = var.sqrt(); // portfolio volatility of the Pledge's borrowed crypto
        let scale = UFP128::from_uint(crank.short.scale);
        let QD = IFP256::from(qd);

        // $ value of borrowed crypto in upward price shocks of avg & bad magnitudes
        // let mut pct = stress(true, vol, true);
        // let avg_val = (one + pct) * eth;
        let pct = stress(false, vol, true);

        let stress_val = (one + pct) * eth;
        let mut stress_loss = stress_val - QD; // stressed value

        // if stress_val > QD that means
        if stress_loss < IFP256::zero() { // TODO this doesn't make sense check cpp
            stress_loss = IFP256::zero(); // better if this is zero, if it's not 
            // that means liquidation (debt value worth > QD collat)
        } 
        // let mut avg_loss = avg_val - QD;
        stats.short.stress_loss += stress_loss.underlying; 
        p.stats.short.stress_loss = stress_loss.underlying;
        
        // stats.short.avg_loss += avg_loss; 
        // p.stats.short.avg_loss = avg_loss.underlying;

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
        due = (
            p.stats.short.premiums / UFP128::from_uint(PERIOD)
        ).value.as_u64().unwrap();

        p.live.short.credit -= due; // the user pays their due by losing a bit of QD collateral
        live.short.credit -= due; // reduce QD collateral in the LivePool
            
        // pay SolvencyProviders by reducing how much they're owed to absorb in QD debt
        if deep.long.credit > due { 
            deep.long.credit -= due;
        } else { // take the remainder and add it to QD collateral to be absorbed from DeepPool
            due -= deep.long.credit;
            deep.long.credit = 0;
            deep.short.debit += due;
        }     
    } 
    if touched {
        storage.stats.write(stats);
        storage.live.write(live);
        storage.deep.write(deep);
        save_pledge(owner, p, true, false);
    }
}
*/
/**
#[storage(read, write)] fn stress_long_pledge(owner: Address) { 
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

    let mut touched = false;
    let mut due = 0;         
    
    // TODO ratio
    p.stats.long.val_ether = price * UFP128::from_uint(p.live.long.credit) / UFP128::from_uint(ONE); // will be sum of each crypto collateral amt * its price
    let val_ether = p.stats.long.val_ether;
    let qd = UFP128::from_uint(p.live.long.debit); // debt
    
    if val_ether > UFP128::zero() {
        // let mut iW = val_ether; // the amount of this crypto in the user's long collateral portfolio, times the crypto's price
        // iW /= val_ether; // 1.0 for now...TODO later each crypto will carry a different weight in the portfolio
        // let var = (iW * iW) * (iVvol * iVvol); // aggregate for all Pledge's crypto collateral
        // let mut vol = var.sqrt(); // total portfolio volatility of the Pledge's crypto collateral
        touched = true;

        let scale = UFP128::from_uint(crank.long.scale); 
        let eth = IFP256::from(val_ether);
        let QD = IFP256::from(qd);

        // $ value of crypto collateral in downward price shocks of bad & avg magnitudes
        // let mut pct = stress(true, vol, false); // TODO assert that pct is within the same precision as one = 100%
        // let avg_val = (one - pct) * eth;
        
        let pct = stress(false, vol, false);
        // model suggested $ value of collat in high stress
        let stress_val = (one - pct) * eth;
        
        // model suggested $ amount of insufficient collat 
        let mut stress_loss = QD - stress_val;
        if stress_loss < IFP256::zero() {   
            stress_loss = IFP256::zero();  
        }
        // let mut avg_loss = QD - avg_val;
        // if avg_loss < IFP256::zero() { 
        //     // TODO raise assertion?
        //     avg_loss = IFP256::zero();   
        // }

        stats.long.stress_loss += stress_loss.underlying; 
        p.stats.long.stress_loss = stress_loss.underlying;
        // stats.long.avg_loss += avg_loss; 
        // p.stats.long.avg_loss = avg_loss.underlying;
        
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
        p.stats.long.rate = pricing(payoff.underlying, 
            scale, val_ether, QD.underlying, vol, false
        ); // APR
        p.stats.long.premiums = p.stats.long.rate * QD.underlying;
        stats.long.premiums += p.stats.long.premiums;

        due = (
            p.stats.short.premiums / UFP128::from_uint(PERIOD)
        ).value.as_u64().unwrap();

        let mut due_in_ether = ratio(ONE, crank.price, due);
        // Debit Pledge's long side for duration
        // (it's credited with ether on creation)
        p.live.long.credit -= due_in_ether; 
        live.long.credit -= due_in_ether;
    
        // pay SolvencyProviders by reducing how much they're owed to absorb in ether debt
        if deep.short.credit > due_in_ether { 
            deep.short.credit -= due_in_ether;
        } else { // take the remainder and add it to ether collateral to be absorbed from DeepPool
            due_in_ether -= deep.short.credit;
            deep.short.credit = 0;
            deep.long.debit += due_in_ether;
        }  
    }
    if touched {
        storage.stats.write(stats);
        storage.live.write(live);
        storage.deep.write(deep);
        save_pledge(owner, p, true, false);
    }
}
*/
impl Quid for Contract 
{    
    // getters just for frontend testing
    #[storage(read)] fn get_live() -> Pool { return storage.live.read(); }
    #[storage(read)] fn get_deep() -> Pool { return storage.deep.read(); }
    // #[storage(read)] fn get_brood() -> Pool { return storage.brood.read(); }

    #[storage(read)] fn get_pledge_live(who: Address) -> Pool {
        let key = storage.pledges.get(who);
        if !(key.try_read().is_none()) {
            let pledge = key.read();
            return pledge.live;
        }
        return Pool {
            long: Pod { credit: 0, debit: 0 },
            short: Pod { credit: 0, debit: 0 },
        }
    }
    #[storage(read)] fn get_pledge_brood(who: Address, eth: bool) -> u64 { 
        let key = storage.pledges.get(who);
        if !(key.try_read().is_none()) {
            let pledge = key.read();
            if eth {
                return pledge.ether;
            }
            return pledge.quid;
        }
        return 0;
    }   

    #[storage(read, write)] fn set_price(price: u64) {
        let mut crank = storage.crank.read();
        crank.price = price;
        storage.crank.write(crank);
    }

    #[payable]
    #[storage(read, write)] fn borrow(amount: u64, short: bool) { // amount in QD 
        let crank = storage.crank.read();
        require(crank.long.done && crank.short.done, UpdateError::Deadlock);

        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, true, true);
        
        let deposit = msg_amount();
        require(amount > ONE, AssetError::BelowMinimum);
        
        let mut live = storage.live.read();
        let mut eth = 0;
        let mut qd = 0;

        // First take care of attached deposit by appending collat
        if msg_asset_id() == contract_id().into() { // QD
            if !short && deposit > 0 {
                eth = redeem(deposit);
            }   
            pledge.live.long.credit += eth;
            live.long.credit += eth;
        }
        else if msg_asset_id() == BASE_ASSET_ID { // ETH
            if short {
                qd = invert(deposit)
            }
            pledge.live.short.credit += qd;
            live.short.credit += qd;
        }
        else {
            revert(42);
        }
        if !short {
            let new_debt = pledge.live.long.debit + amount;
           
            let cr = calc_cr(crank.price, pledge.live.long.credit, new_debt, false);
            if cr >= MIN_CR { // requested amount to borrow is within measure
                mint(contract_id().into(), amount);
                pledge.live.long.debit = new_debt;
                live.long.debit += amount;
            } 
            else { // instead of throwing a "below MIN_CR", try to flash loan
                // pledge = valve(account,
                //     false, new_debt, 
                //     live.long, pledge.live.long
                // ); 
            }
        } 
        else {
            eth = ratio(ONE, amount, crank.price); // convert QD value to ETH amount
            let new_debt = pledge.live.short.debit + eth;

            let cr = calc_cr(crank.price, pledge.live.short.credit, new_debt, true);
            if cr >= MIN_CR {
                pledge.live.short.debit = new_debt; // this is how much crypto must be 
                // eventually bought back (at a later price) to repay debt
                live.short.debit += eth;
            }
            else {
                let new_debt_in_qd = ratio(crank.price, new_debt, ONE); 
                // pledge = valve(account,
                //     true, new_debt_in_qd, 
                //     live.short, pledge.live.short
                // );
            }

        }
        save_pledge(account, pledge, !short, short);
    }

    // Close out caller's borrowing position by paying
    // off all pledge's own debt with own collateral
    #[storage(read, write)] fn fold(short: bool) { 
        // TODO take an amount, if amount is zero
        // then fold the whole pledge
        // otherwise shrink by amount

        let mut brood = storage.brood.read();
        let crank = storage.crank.read();
        require(crank.price > 0, PriceError::NotInitialized);

        let sender = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(sender, false, true);
        
        if short { 
            let eth = pledge.live.short.debit;
            // this is how much QD collat we are returning to SP from LP
            let qd = ratio(crank.price, eth, ONE); 
            // TODO instead of decrementing from DP
            // write how much is being debited against DP
            // assert that this never exceeds DP balance
            // as such, while payments are being made out 
            // of DP into SP...maintain invariant that 
            // when SP withdraws 
            redeem(qd); // assume this QD comes from collat,
            // which we actually burn off in the next function
            // TODO 
            // possible bug ETH can leave SP
                // paydown the debt in the pledge
                // but that ETH stays in the contract
                // and it is no longer available to SP withdrawl?
            churn(eth, true, sender); // reduce ETH debt
            // send ETH back to SP since it was borrowed from
            // there in the first place...but since we redeemed
            // the QD that was collat, we were able to clear some
            // long liquidatons along the way, destroying debt
            // brood.debit += 
        } else { // TODO all the same logic as above applies in shrink
            let eth = ratio(ONE, pledge.live.long.debit, crank.price);
            invert(eth);
             // TODO dont go into deep first go into SP
            // if SP wants to withdraw, QD value only
            // DP coll goes into SP, debt goes into LP
            // verify with borrow function 
            churn(pledge.live.long.debit, false, sender);
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
        require(amt > 0, AssetError::BelowMinimum);
        let mut pledge = fetch_pledge(sender, true, true);

        if msg_asset_id() == contract_id().into() { // QD
            require(amt > ONE, AssetError::BelowMinimum); 
            if live { // adding collat to LP
                let mut pool = storage.live.read(); 
                if long { 
                    if pledge.live.long.debit > 0 { // try pay down debt
                        let qd = min(pledge.live.long.debit, amt);
                        pledge.live.long.debit -= qd;
                        amt -= qd;
                        // TODO should we burn QD from the supply?
                    }
                    if amt > 0 { 
                        // TODO
                        // redeem remaining QD 
                        // deposit ETH suretty 
                    }
                }
                else { // short
                    pledge.live.short.credit += amt;
                    pool.short.credit += amt;
                    storage.live.write(pool);
                }
            } 
            else { // adding collat to SP
                pledge.quid += amt;
                let mut pod = storage.brood.read();
                pod.credit += amt;
                storage.brood.write(pod);   
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
                        // deposit QD collat
                    }   
                }
            }
            else { pledge.ether += amt;
                let mut pod = storage.brood.read();
                pod.debit += amt;
                storage.brood.write(pod);
            }
        } 
        else {
            revert(42);
        }
        storage.pledges.insert(sender, pledge); // TODO save_pledge
    }

    // https://www.lawinsider.com/dictionary/loan-agreement-rider
    // if clap have a value attached to it, this is debt restructuring
    // collateral is held in escrow 
    // repayment schedule
    #[payable]
    #[storage(read, write)] fn clap(who: Address) { // who...who? what're you a fuckin owl
        // riders try save using the callers pledge against target
        // if success attach caller as a rider on the loan 

        let mut pledge = fetch_pledge(who, false, true);
        // if account is paying 2x from initial collateral
        // 
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
    #[storage(read, write)] fn withdraw(amt: u64, qd: bool, sp: bool) {
        let crank = storage.crank.read();
        require(crank.price > ONE, PriceError::NotInitialized);
        require(amt > 0, AssetError::BelowMinimum);
        
        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, false, true);
        
        // TODO if withdrawal out of SP and not INTO it
        // sync must be true because what if timing withdrawl
        // right before liquidation, takes in % of losses owed
        // depending on withdrawal amount (and it's % of total solvency)

        let mut least: u64 = 0; 
        let mut cr: u64 = 0; 
        if !qd {
            if !sp {
                // TODO
                // compare original position value to current
                // do not take fee if current value is less 

                let mut pool = storage.live.read(); // Pay withdraw fee
                least = min(pledge.live.long.credit, (amt + amt/100));
                pledge.live.long.credit -= least;
                
                cr = calc_cr(crank.price, pledge.live.long.credit, pledge.live.long.debit, false);    
                require(cr >= MIN_CR, ErrorCR::BelowMinimum);
                
                pool.long.credit -= least;
                storage.live.write(pool); 
            } 
            else {
                let mut pod = storage.brood.read();
                least = min(pledge.ether, amt); 
                pledge.ether -= least;
                pod.debit -= least;
                storage.brood.write(pod);

                // 
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
                let mut pod = storage.brood.read();
                least = min(pledge.quid, amt); 
                pledge.quid -= least;
                pod.credit -= least;
                storage.brood.write(pod);
            }
            transfer(Identity::Address(account), contract_id().into(), least);
        }
        storage.pledges.insert(account, pledge); 
    }
    
    #[storage(read, write)] fn update_shorts() {
        let mut crank = storage.crank.read();
        let mut live = storage.live.read();
        let mut deep = storage.deep.read();
        if !crank.short.done {
            let len = storage.sorted_shorts.len();
            let mut start = crank.short.index;
            let left = len - start;
            let mut many = 11; // arbitrary number of Pledges to iterate at a time
            // limited by maximum gas that can be burned in one transaction call
            if 11 > left {   
                 many = left;    
            }
            let stop = start + many;
            while start < stop { 
                let id = storage.sorted_shorts.get(start).unwrap().read();
                // stress_short_pledge(id); // TODO uncomment after Sway compiler fixed
                // TODO delete ~20 lines below after uncommenting the line above
                let mut pledge = fetch_pledge(id, false, false);
                let mut due = pledge.live.short.credit / 6000; // roughly 16% / 365 / 3 times a day
                
                pledge.live.short.credit -= due; // the user pays their due by losing a bit of QD collateral
                live.short.credit -= due; // reduce QD collateral in the LivePool
                    
                // pay SolvencyProviders by reducing how much they're owed to absorb in QD debt
                if deep.long.credit > due { 
                    deep.long.credit -= due;
                } else { // take the remainder and add it to QD collateral to be absorbed from DeepPool
                    due -= deep.long.credit;
                    deep.long.credit = 0;
                    deep.short.debit += due;
                }
                storage.pledges.insert(id, pledge);     
                crank.short.index += 1;
                start += 1;
            }
            if crank.short.index == len {
                crank.short.index = 0;
                crank.short.done = true;
            }
        } 
        storage.crank.write(crank);
        storage.live.write(live);
        storage.deep.write(deep);
    }
    
    
    // 500000000 is the max gas a tx call can accept
    // A external maintenance script must call this regularly, 
    // in order to drive stress testing, re-pricing options for 
    // borrowers on account of this, and SolvencyTarget as SP's 
    // weighted-median voting concedes the target solvency 
    // TODO refactor try breaking into two separate functions, or compiler freezes
    #[storage(read, write)] fn update_longs() {
        let mut crank = storage.crank.read();
        let mut live = storage.live.read();
        let mut deep = storage.deep.read();
        if !crank.long.done {
            let len = storage.sorted_longs.len();
            let mut start = crank.long.index;
            let left = len - start;
            let mut many = 11; // arbitrary number of Pledges to iterate at a time
            // limited by maximum gas that can be burned in one transaction call
            if 11 > left {   
                 many = left;    
            }
            let stop = start + many;
            while start < stop { 
                let id = storage.sorted_longs.get(start).unwrap().read();
                // stress_long_pledge(id); // TODO uncomment after Sway compiler fixed
                // TODO delete ~20 lines below after uncommenting the line above
                let mut pledge = fetch_pledge(id, false, false);
                let mut due = pledge.live.long.credit / 6000; // roughly 16% / 365 / 3 times a day
                let mut due_in_ether = ratio(ONE, crank.price, due);
                // Debit Pledge's long side for duration
                // (it's credited with ether on creation)
                pledge.live.long.credit -= due_in_ether; 
                live.long.credit -= due_in_ether;
                // pay SolvencyProviders by reducing how much they're owed to absorb in ether debt
                if deep.short.credit > due_in_ether { 
                    deep.short.credit -= due_in_ether;
                } else { // take the remainder and add it to ether collateral to be absorbed from DeepPool
                    due_in_ether -= deep.short.credit;
                    deep.short.credit = 0;
                    deep.long.debit += due_in_ether;
                }  
                storage.pledges.insert(id, pledge);
                crank.long.index += 1;
                start += 1;
            }
            if crank.long.index == len {
                crank.long.index = 0;
                crank.long.done = true;
            }
        } 
        storage.crank.write(crank);
        // TODO uncomment these lines after sway compiler is fixed
        storage.live.write(live);
        storage.deep.write(deep);        
    }  
    
    #[storage(read, write)] fn update() {
        let mut crank = storage.crank.read();
        let mut stats = storage.stats.read();
        let brood = storage.brood.read();
        // the first time we call update in one cycle, done = true
        // that means we need to calculate global risk...that gives us 
        // scale variable that is used for individual pledge pricing  
        if crank.long.done && crank.short.done {
            let time = timestamp();
            let time_delta = time - crank.last_update;
            // TODO make the constant an enum that can be one of a few consts based on governance?
            if time_delta >= EIGHT_HOURS {
                let price = crank.price;
                stats.val_ether_sp = // UFP128::from_uint(
                    ratio(price, brood.debit, ONE);
                // );
                // stats.val_total_sp = UFP128::from_uint(brood.credit) + stats.val_ether_sp;
                stats.val_total_sp = brood.credit + stats.val_ether_sp;
                storage.stats.write(stats);
                // TODO uncomment these lines when compiler is fixed
                // sp_stress(None, false); // stress the long side of the SolvencyPool
                // sp_stress(None, true); // stress the short side of the SolvencyPool
                // risk(false); risk(true); // calculate solvency and scale factor 
                crank.long.done = false;
                crank.short.done = false;
                crank.last_update = timestamp();
            } 
            else {
                require(true, UpdateError::TooEarly); 
            }
            storage.crank.write(crank);
        }
    }
}

// TODO uncomment after fixed point compilation error is fixed
/**
#[storage(read, write)] fn sp_stress(maybe_addr: Option<Address>, short: bool) -> UFP128 {
    let mut stats = storage.stats.read();
    let crank = storage.crank.read();
    let brood = storage.brood.read();
    
    let ivol = UFP128::from_uint(crank.vol); // get annualized volatility of ETH
    let price = UFP128::from_uint(crank.price);
    
    let mut global = true;
    let mut iW = UFP128::zero(); 
    let mut jW = UFP128::zero();

    let one = UFP128::from_uint(ONE);
    let two = UFP128::from_uint(TWO);

    if stats.val_ether_sp > UFP128::zero() {
        iW = stats.val_ether_sp / stats.val_total_sp;
        jW = UFP128::from_uint(brood.credit) / stats.val_total_sp;
    }
    if let Some(addr) = maybe_addr {
        global = false;
        let key = storage.pledges.get(addr);
        if key.try_read().is_none() {
            // revert
        } else {
            let p = key.read();
            let val_ether = UFP128::from_uint(
                ratio(crank.price, p.ether, ONE)
            );
            let value = UFP128::from_uint(p.quid) + val_ether;

            let mut delta_eth = UFP128::zero();
            let mut delta_qd = UFP128::zero();
            if value > UFP128::zero() {
                if stats.val_ether_sp > UFP128::zero() {
                    delta_eth = stats.val_ether_sp - val_ether;
                }
                if brood.credit > 0 {
                    delta_qd = UFP128::from_uint(brood.credit - p.quid);
                }
                let delta_val = stats.val_total_sp - value;
                
                iW = delta_eth / delta_val;
                jW = delta_qd / delta_val;
            }            
        }
    }
    let var = (two * iW * jW * ivol) + (iW * iW * ivol * ivol);
    if var > UFP128::zero() {
        let vol = var.sqrt(); // total volatility of the SolvencyPool
        // % loss that total SP deposits would suffer in a stress event
        let stress_pct = stress(false, vol, short);
        let avg_pct = stress(true, vol, short);
        
        let mut stress_val = stats.val_total_sp;
        let mut avg_val = stress_val;
        
        if !short {
            stress_val *= one - stress_pct.underlying; 
            avg_val *= one - avg_pct.underlying;
            if global {
                stats.long.stress_val = stress_val;
                stats.long.avg_val = avg_val;
            } 
        } 
        else {
            stress_val *= one + stress_pct.underlying;
            avg_val *= one + avg_pct.underlying;
            if global {
                // TODO verify that the aggregated values from 
                // stress_short_pledge evaluate to the above
                // plus or minus some discrepancy
                stats.short.stress_val = stress_val;
                stats.short.avg_val = avg_val;
            } 
        }
        storage.stats.write(stats);
        return stress_val;
        
    } else {
        return UFP128::zero();
    }
}
*/

/**
#[storage(read, write)] fn risk(short: bool) {
    let mut crank = storage.crank.read();
    let mut stats = storage.stats.read();
    let live = storage.live.read();

    let mut mvl_s = IFP256::zero(); // market value of liabilities in stressed markets 
    let mut mva_s = IFP256::zero(); // market value of assets in stressed markets 
    let mut mva_n = IFP256::from(stats.val_total_sp); // market value of insurance assets 
    // sureties are not an asset of the insurers

    let one = IFP256::from(UFP128::from_uint(ONE));
    let mut neg_one = one; 
    neg_one = neg_one.sign_reverse();
    
    let mut val_ether = IFP256::zero();
    let mut vol = UFP128::from_uint(crank.vol);
    
    if !short {
        val_ether = IFP256::from(
            UFP128::from_uint(
                ratio(crank.price, live.long.credit, ONE)
            )
        );
        let qd = IFP256::from(UFP128::from_uint(live.long.debit));
        let mut pct = stress(false, vol, false);
        
        let stress_val = (one - pct) * val_ether;
        let stress_loss = qd - stress_val;
        
        mva_s = stress_val; // self.stats.long.stress_val;
        mvl_s = stress_loss; // self.stats.long.stress_loss;
    } else {
        val_ether = IFP256::from(
            UFP128::from_uint(
                ratio(crank.price, live.short.debit, ONE)
            )
        );
        let qd = IFP256::from(
            UFP128::from_uint(live.short.credit)
        );
        let mut pct = stress(false, vol, true);
        let stress_val = (one + pct) * val_ether;
        let stress_loss = stress_val - qd;

        mva_s = stress_val; // self.stats.short.stress_val;
        mvl_s = stress_loss; // self.stats.short.stress_loss;
    }    
    let own_n = mva_n; // own funds normal markets
    let mut own_s = mva_s - mvl_s; // own funds stressed markets
    if short && own_s > IFP256::zero() {
        own_s *= neg_one;   
    }
    // S.olvency C.apial R.equirement is the amount of... 
    // deposited assets needed to survive a stress event
    let scr = own_n - own_s;
    require(scr > IFP256::zero(), SCRerror::CannotBeZero);
    let solvency = own_n / scr; // represents capital adequacy to back $QD
    // TODO uncomment and replace short target
    if short {
        let mut target = crank.short.target;
        let mut scale = IFP256::from_uint(target) / solvency;
 
        crank.short.scale = scale.underlying.value.as_u64().unwrap();
        crank.short.solvency = solvency.underlying;
    } 
    else {
        let mut target = crank.long.target;
        let mut scale = IFP256::from_uint(target) / solvency;
        
        crank.long.scale = scale.underlying.value.as_u64().unwrap();
        crank.long.solvency = solvency.underlying;
    }
    storage.crank.write(crank);
    // storage.stats.write(stats);
}
*/

// TODO find the biggest one first, with the lowest CR (less than 1.1)
// keep going down by size until you find one with appropriate CR
// then keep clipping by ascending CR until you've satisfied the amount
/**
#[storage(read, write)] fn churn_from(amt: u64, short: bool, sender: Address) -> u64 {


}
*/

#[storage(read, write)] fn churn(amt: u64, short: bool, sender: Address) -> u64 {
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


#[storage(read, write)] fn redeem(quid: u64) -> u64 {
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
                let mut brood = storage.brood.read();
                let mut eth = ratio(ONE, amt, crank.price);
                assert(this_balance(BASE_ASSET_ID) > eth);

                let mut least = min(brood.debit, eth); 
                amt = ratio(crank.price, amt, ONE); // QD paid to SP for ETH sold 
                // storage.token.internal_deposit(&env::current_account_id(), amt); TODO

                brood.credit += amt; // offset, in equal QD value, the ETH sold by SP
                brood.debit -= least; // sub ETH that's getting debited out of the SP
                storage.brood.write(brood);
                
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
    return quid; // TODO calculate how much ETH was returned
}

// A debit to a liability account means the amount owed is reduced,
// and a credit to a liability account means it's increased. 

#[storage(read, write)] fn invert(eth: u64) -> u64 { // inverted air conditions add efficiency to 
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
            let mut brood = storage.brood.read();
            
            let mut quid = ratio(crank.price, amt, ONE);            
            let min_qd = min(quid, brood.credit);
            let min_eth = ratio(ONE, min_qd, crank.price);
            
            // storage.token.internal_withdraw(&env::current_account_id(), min); TODO
            brood.debit += min_eth;
            brood.credit -= min_qd;
            storage.brood.write(brood);
            
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
    return eth; // TODO return how much QD was bought for ETH
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
// so debt from DP goes back to LP
// but never collat 
#[storage(read, write)] fn snatch(db: u64, collat: u64, short: bool) { 
    let crank = storage.crank.read();
    let mut live = storage.live.read();
    let mut deep = storage.deep.read();
    require(crank.price > 0, PriceError::NotInitialized);
    if short { // we are moving crypto debt and QD collateral from LivePool to DP
        live.short.credit -= collat; // collat is in QD
        deep.short.credit += collat;
        live.short.debit -= db; // db is in ETH
        
        let val_debt = ratio(crank.price, db, ONE); // get db in QD
        let delta = val_debt - collat; 
        // let delta: I8 = I8::from(db - val_coll);
        assert(delta > 0); // borrower was not supposed to be liquidated
        
        let delta_debt = ratio(ONE, delta, crank.price);
        let debt_minus_delta = db - delta_debt;

        deep.short.debit += debt_minus_delta;

        // clearing delta_debt against 11% tax from sale
    } 
    else { // we are moving QD debt and crypto collateral
        live.long.credit -= collat;
        deep.long.credit += collat;
        live.long.debit -= db;

        let val_coll = ratio(crank.price, collat, ONE);

        assert(db > val_coll);
        // let delta: I64 = I64::from(db - val_coll);
        // assert(delta > I64::from(0)); // borrower was not supposed to be liquidated
        let delta = db - val_coll;
        let db_minus_delta = db - delta; //.into();

        deep.long.debit += db_minus_delta;

        // clearing delta against 11% tax from sale
    }
}

#[storage(read, write)] fn try_clap(id: Address, SPod: Pod, LPod: Pod, short: bool, price: u64) -> (u64, u64, u64, u64) {
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
    let old_blood = storage.brood.read();

    if short {
        nums = short_save(SPod, LPod, price);
        cr = calc_cr(price, nums.1, nums.3, true); // side
        let mut new_live = storage.live.read();
        let mut new_blood = storage.brood.read();
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
                storage.brood.write(new_blood);
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
        let mut new_blood = storage.brood.read();
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
                storage.brood.write(new_blood);
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
    let mut brood = storage.brood.read();

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
        brood.debit -= least; // remove eth from SP
    }
    if delta > 0 && quid > 0 { // 
        // recalculate delta in units of QD
        delta -= ratio(price, delta, ONE); 
        
        least = min(quid, delta);
        quid -= least;
        debit -= least;
        
        brood.credit -= least;
        live.long.debit -= least;
    }
    storage.brood.write(brood);
    storage.live.write(live);
    
    return (ether, credit, quid, debit); // we did the best we could, 
    // but there is no guarantee that the CR is back up to MIN_CR
}

#[storage(read, write)] fn short_save(SPod: Pod, LPod: Pod, price: u64) -> (u64, u64, u64, u64) {
    let crank = storage.crank.read();
    let mut live = storage.live.read();
    let mut brood = storage.brood.read();
    
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
    // to be in collat for satisfying the minimum loan collateralisation 

    let mut delta = final_qd - credit; // $ value to add for credit 
    require(delta > 0, LiquidationError::UnableToLiquidate);

    let mut least = min(quid, delta);
    if least > 0 {
        delta -= least;
        quid -= least;
        brood.credit -= least;    

        credit += least;
        live.short.credit += least;
    }
    if delta > 0 && ether > 0 { // delta was not covered fully
        // recalculate delta in units of ETH
        delta = ratio(ONE, delta, price);
        
        least = min(ether, delta);
        ether -= least;
        debit -= least;

        brood.debit -= least;
        live.short.debit -= least;
    }
    storage.brood.write(brood);
    storage.live.write(live);

    return (quid, credit, ether, debit);
}
