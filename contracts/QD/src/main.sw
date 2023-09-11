
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
    // constants::ZERO_B256,
    constants::BASE_ASSET_ID,
    token::transfer,
    storage::storage_vec::*,
};

storage {
    pledges: StorageMap<Address, Pledge> = StorageMap {},
    sorted_shorts: StorageVec<Address> = StorageVec {}, 
    sorted_longs: StorageVec<Address> = StorageVec {}, 
    live: Pool = Pool { // Active borrower assets
        long: Pod { credit: 0, debit: 0, }, // ETH, QD
        short: Pod { credit: 0, debit: 0, }, // QD, ETH
    },
    deep: Pool = Pool { // Defaulted borrower assets
        long: Pod { credit: 0, debit: 0, }, // 
        short: Pod { credit: 0, debit: 0, }, //
    },
    blood: Pod = Pod { // Solvency Pool deposits 
        credit: 0, // QD
        debit: 0 // ETH
    },
    crank: Crank = Crank { done: true, 
        index: 0, last: 0, price: ONE, // eth price in usd * qd price in usd
    },
}

// private functions before public

#[storage(read, write)] fn fetch_pledge(owner: Address, create: bool, sync: bool) -> Pledge {
    let key = storage.pledges.get(owner);
    if key.try_read().is_none() {
        if create {
            let pledge = Pledge {
                live: Pool {
                    long: Pod { credit: 0, debit: 0 },
                    short: Pod { credit: 0, debit: 0 },
                },
                stats: PledgeStats {                
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
                }, ether: 0, quid: 0
            };
        } else {
            revert(420);
        }
    } else {
        if sync {
            //
        }
    }
    return key.read();
}

impl Quid for Contract 
{    
    // Close out caller's borrowing position by paying
    // off all pledge's own debt with own collateral
    #[storage(read, write)] fn fold(short: bool) { 
        let crank = storage.crank.read();
        require(crank.price > 0, PriceError::NotInitialized);

        let sender = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(sender, false, true);
        
        if short {
            let cr = calc_cr(crank.price, pledge.live.short.credit, pledge.live.short.debit, true);
            if cr >= ONE {
                // this is how much QD surety we are returning to SP from LP
                let qd = ratio(crank.price, pledge.live.short.debit, ONE); 
                

                redeem(qd, true); // assume this QD comes from surety,
                // which we actually burn in the next function
                // TODO 
                // bug ETH can leave SP
                    // paydown the debt in the pledge
                    // but that ETH stays in the contract
                    // and it is no longer available to SP withdrawl?

                turn(pledge.live.short.debit, true, sender); // reduce ETH debt
                
            }
        } else {
            let cr = calc_cr(crank.price, pledge.live.long.credit, pledge.live.long.debit, false);
            if cr > ONE {
                let eth = ratio(ONE, pledge.live.long.debit, crank.price);
                // invert(eth);
                turn(pledge.live.long.debit, false, sender);
            }
        }   
    }

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
     * a user's SolvencyPool deposit, or LivePool (borrowing) position.
     * Thus, the first boolean parameter's for indicating which pool,
     * & last boolean parameter indicates currency being withdrawn. 
     */
    #[storage(read, write)] fn withdraw(amt: u64, qd: bool, sp: bool) 
    {    
        let crank = storage.crank.read();
        require(crank.price > ONE, PriceError::NotInitialized);
        require(amt > 0, AssetError::BelowMinimum);
        
        let account = get_msg_sender_address_or_panic();
        let mut pledge = fetch_pledge(account, false, true);
        
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
    
    if !short { // use QD to clear QD debt in long
        least = min(pledge.live.long.debit, amt); 
        if least > 0 { 
            pledge.live.long.debit -= least;
            pool.long.debit -= least;

            let redempt = ratio(ONE, least, crank.price); // get ETH
            pledge.live.long.credit -= redempt; 
            pool.long.credit -= redempt;
        }
    } 
    else { // use ETH to clear ETH amt of debt in short
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

#[storage(read, write)] fn redeem(quid: u64, fold: bool) {
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
            if !fold { // when folding the ETH displaced returns to DP
                // How much ETH we're about to displace in the deepPool    
                deep.long.debit -= ratio(ONE, redempt, crank.price);
                
                if amt > 0 { // there is remaining QD to redeem after redeeming from deepPool  
                    let mut eth = ratio(ONE, amt, crank.price);
                    assert(this_balance(BASE_ASSET_ID) > eth);

                    // let mut min = min(storage.brood.debit, eth); // maximum ETH dispensable by SolvencyPool
                    // amt = ratio(storage.price, amt, ONE); // QD paid to SP for ETH sold 
                    // // storage.token.internal_deposit(&env::current_account_id(), amt); TODO
                    // storage.brood.credit += amt; // offset, in equal value, the ETH sold by SP
                    // storage.brood.debit -= min; // sub ETH that's getting debited out of the SP
                    
                    // eth -= min;
                    if eth > 0 { // TODO up to a limit  
                        amt = ratio(crank.price, eth, ONE); // in QD
                        // storage.token.internal_deposit(&env::current_account_id(), amt); TODO
                        // DP's QD will get debited (canceling ETH debt) in inversions
                        deep.short.debit += amt;
                        // append defaulted ETH debt to the DP as retroactive settlement
                        deep.short.credit += eth;
                    }
                }
            }
            storage.deep.write(deep);
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
/**
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
*/