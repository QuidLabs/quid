contract;

mod helpers;
use helpers::*;

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
    constants::BASE_ASSET_ID,
    // storage::{StorageMap, StorageVec, get, store},
    storage::*,
    u128::U128,
    contract_id::ContractId,
    token::*,
};

abi Quid {
    // Sends an amount of existing quid.
    // Can be called from any address.
    #[storage(read, write)] fn send (receiver: Address, amount: u64);

    #[storage(read, write)] fn deposit (live: bool, qd_amt: u64, eth_amt: u64);

    #[storage(read, write)] fn fold (short: bool); // use collateral to repay debt and withdraw remainder

    #[storage(read, write)] fn renege (amt: u64, sp: bool, qd: bool); // withdraw: collateral/solvency deposit

    #[storage(read, write)] fn clap (who: Address); // liquidate

    #[storage(read, write)] fn clear (amount: u64, repay: bool, short: bool); 

    #[storage(read, write)] fn borrow (amount: u64, short: bool); 

    // #[storage(read, write)] fn update (); 
}

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
    
    // TODO layer it in leverage
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
                transfer_to_output(amt, BASE_ASSET_ID, account); // send ETH to msg.sender
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
            transfer_to_output(amt_sub_fee, BASE_ASSET_ID, account); // send ETH to msg.sender
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

                transfer_to_output(eth, BASE_ASSET_ID, account); // send ETH to redeemer
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

