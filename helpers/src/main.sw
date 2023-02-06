library helpers;

use core::num::*;
use std::{
    address::*,
    block::*,
    chain::auth::*,
    context::{*, call_frames::*},
    result::*,
    revert::revert,
    identity::Identity,
    u128::U128,
    math::*,
};

pub const ONE: u64 = 1_000_000; // 6 digits of precision, same as USDT

pub fn mini(left: u64, right: u64) -> u64 {
    if right > left {
        return right;
    }
    return left;
}

pub fn ratio(multiplier: u64, numerator: u64, denominator: u64) -> u64 { 
    let calculation = (~U128::from(0, numerator) * ~U128::from(0, multiplier));
    let result_wrapped = (calculation / ~U128::from(0, denominator)).as_u64();

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
        return ~u64::max();
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