
library quid_abi;

use std::{
    address::Address,
    storage::*
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
