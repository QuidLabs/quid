
library;

use std::{
    auth::*,
    u128::U128
};

use fixed_point::ufp128::UFP128;
use fixed_point::ifp256::IFP256;

pub enum VoteError {
    BadVote: (),
}

pub enum LiquidationError {
    UnableToLiquidate: (),
}

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
    stress_val: u64, //  $ value of the Solvency Pool in bad market stress, tail risk
    avg_val: u64, // $ value of the Solvency Pool in average stress, 25-50 % price shock
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
    // TODO to_be_paid gets incremented on every borrow ??
    // this is paid from the body of the collateral (
    // coming from an external source )
    //
    stats: PledgeStats, // risk management metrics
    ether: u64, // SolvencyPool deposit of ETH
    quid: u64, // SolvencyPool deposit of $QD
    // index: u64
    // last_voted: u64, // TODO do we need to save the vote itself
}

pub struct Crank {
    done: bool, // currently updating
    index: u64, // amount of surety
    last: u64, // timestamp of last time Crank was updated
    price: u64, // TODO timestamp of last time price was update
    sum_w_k: u64, // sum(W[0..k])
    k: u64, // approx. index of median (+/- 1)
}

pub const TEN: u64 = 10_000_000_000;
pub const ONE: u64 = 1_000_000_000; // 9 digits of precision, same as ETH
pub const TWO: u64 = ONE * 2; 
pub const MIN_CR: u64 = 1_100_000_000; 
pub const PI = UFP128::from_uint(3141592653);
pub const TWO_PI = UFP128::from_uint(2 * 3141592653);
pub const LN_TEN = UFP128::from_uint(2302585093);

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
            // TODO revert actually?
        }
    } 
    else if _surety > 0 {
        return u64::max();
    }
    return 0; // this is normal, means no leverage
}

// https://math.stackexchange.com/questions/2621005/
// The absolute value of the error should be less than 4.5 e-4.
pub fn RationalApproximation(t: UFP128) -> UFP128 {  
    let one = UFP128::from_uint(ONE);
    let c: [UFP128; 3] = [
        UFP128::from_uint(2515517000), 
        UFP128::from_uint(802853000), 
        UFP128::from_uint(10328000)
    ];
    let d: [UFP128; 3] = [
        UFP128::from_uint(1432788000), 
        UFP128::from_uint(189269000), 
        UFP128::from_uint(1308000)
    ];
    t - ((c[2] * t + c[1]) * t + c[0]) / 
        (((d[2] * t + d[1]) * t + d[0]) * t + one)
}

pub fn ln(x: UFP128) -> UFP128 {
    let result = x.value.log(UFP128::from_uint(TEN).value) / LN_TEN.value;
    return UFP128::from(result.into());
}

pub fn NormalCDFInverse(p: UFP128) -> IFP256 {
    let one = UFP128::from_uint(ONE);
    assert(p > UFP128::zero() && p < one);
    // ln is undefined for x <= 0
    
    let mut neg_one = IFP256::from(one);
    neg_one = neg_one.sign_reverse();

    let two = UFP128::from_uint(TWO);
    let mut neg_two = IFP256::from(two);
    neg_two = neg_two.sign_reverse();

    // See article above for explanation of this section.
    if p < one / two { // F^-1(p) = -G^-1(p)
        let n: IFP256 = neg_two * IFP256::from(ln(p));
        assert(n > IFP256::zero());
        let n_unsigned: UFP128 = n.into();
        return neg_one * IFP256::from(RationalApproximation( n_unsigned.sqrt() ));
    }
    else { // F^-1(p) = G^-1(1-p)
        let l = one - p;
        let n: IFP256 = neg_two * IFP256::from(ln(l));
        assert(n > IFP256::zero());
        let n_unsigned: UFP128 = n.into();
        return IFP256::from(RationalApproximation( n_unsigned.sqrt() ));
    }
}

/**
// calculate % loss given short Pledge's portfolio volatility & the statistical assumption of normality
pub fn stress(avg: bool, sqrt_var: f64, short: bool) -> f64 { // max portfolio loss in %
    let mut alpha: f64 = 0.90; // 10% of the worst case scenarios
    if avg {
        alpha = 0.50;  // 50% of the avg case scenarios
    }
    let cdf = NormalCDFInverse(alpha);
    let e1 = -1.0 * (cdf * cdf) / 2.0;
    let mut e2 = ((e1.exp() / TWO_PI.sqrt()) / (1.0 - alpha)) * sqrt_var;
    if short {
        return e2.exp() - 1.0;    
    } else {
        e2 *= -1.0;
        return -1.0 * (e2.exp() - 1.0);
    }
}

// Used for pricing put & call options for borrowers contributing to the ActivePool
pub fn price(payoff: f64, scale: f64, val_crypto: f64, val_quid: f64, ivol: f64, short: bool) -> f64 {
    let max_rate: f64 = 0.42;
    let min_rate: f64 = 0.0042 * scale; // * calibrate
    let sqrt_two: f64 = 2.0_f64.sqrt();
    let div = val_crypto / val_quid;
    let ln = div.ln();
    let d: f64 = (ln + (ivol * ivol / -2.0)/* times calibrate */) / ivol; // * calibrate
    let D = d / sqrt_two;
    let mut rate: f64;
    if short { // erfc is used instead of normal distribution
        rate = (payoff * libm::erfc(-1.0 * D) / 2.0) / val_crypto;
    } else {
        rate = (payoff * libm::erfc(D) / 2.0) / val_quid;
    }
    // rate *= calibrate;
    if rate > max_rate {
        rate = max_rate;
    } else if rate < min_rate {
        rate = min_rate;
    }
    return rate;
}
*/