
library;

use std::{
    auth::*,
    u128::U128
};

pub enum PriceError {
    NotInitialized: (),
}

pub enum ErrorCR {
    BelowMinimum: ()
}

pub enum AssetError {
    BelowMinimum: (),
}

pub enum PoolError {
    BelowMinimum: (),
}

pub struct Pod { // Used in all Pools, and in individual users' Pledges
    credit: u64, // amount of QD surety in shorts, ETH in longs
    debit: u64 // amount of QDebt in longs, ETH debt in shorts
} 

pub struct Pool { // Pools have a long Pod and a short Pod
    long: Pod, // debt and surety of QD borrowers
    short: Pod, // debt and surety of ETH borrowers
} 

pub struct Stats {
    val_ether: u64, // $ value of ETH assets
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
    val_ether_sp: u64, // $ value of the ETH solvency deposit
    val_total_sp: u64, // total $ value of val_eth + $QD solvency deposit
}

pub struct Pledge { // each User pledges
    live: Pool, // surety in $QD or ETH
    stats: PledgeStats, // risk management metrics
    ether: u64, // SolvencyPool deposit of NEAR
    quid: u64, // SolvencyPool deposit of $QD
}

pub struct Crank {
    done: bool, // currently updating
    index: u64, // amount of surety
    last: u64, // timestamp of last time Crank was updated
    price: u64,
}

pub const ONE: u64 = 1_000_000_000; // 9 digits of precision, same as ETH
pub const MIN_CR: u64 = 1_100_000_000; // 9 digits of precision, same as ETH

pub fn get_msg_sender_address_or_panic() -> Address {
    let sender: Result<Identity, AuthError> = msg_sender();
    if let Identity::Address(address) = sender.unwrap() {
       address
    } else {
       revert(420);
    }
}

pub fn min(left: u64, right: u64) -> u64 {
    if right > left {
        return right;
    }
    return left;
}

pub fn ratio(multiplier: u64, numerator: u64, denominator: u64) -> u64 { 
    let calculation = (U128::from((0, numerator)) * U128::from((0, multiplier)));
    let result_wrapped = (calculation / U128::from((0, denominator))).as_u64();

    // TODO remove workaround once https://github.com/FuelLabs/sway/pull/1671 lands.
    match result_wrapped {
        Result::Ok(inner_value) => inner_value, _ => revert(0), 
    }
}

pub fn calc_cr(_price: u64, _surety: u64, _debt: u64, _short: bool) -> u64 {
    if _debt > 0 {
        if _surety > 0 {
            if _short {
                let debt_in_qd = ratio(_price, _debt, ONE);
                return ratio(ONE, _surety, debt_in_qd);
            } else {
                return ratio(_price, _surety, _debt);
            }
        }
        else {
            return 0;
        }
    } 
    else if _surety > 0 {
        return u64::max();
    }
    return 0;
}
