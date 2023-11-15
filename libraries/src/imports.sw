
library;

use std::{
    auth::*,
    u128::U128,
};

// use fixed_point::ufp128::UFP128;
// use fixed_point::ifp256::IFP256;

pub enum VoteError {
    BadVote: (),
}

pub enum SCRerror {
    CannotBeZero: (),
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

pub enum UpdateError {
    TooEarly: (),
    Deadlock: ()
}

pub struct Pod { // Used in all Pools, and in individual users' Pledges
    credit: u64, // amount of QD collat in shorts, ETH in longs
    debit: u64 // amount of QDebt in longs, ETH debt in shorts
} 

pub struct Pool { // Pools have a long Pod and a short Pod
    long: Pod, // debt and collat of QD borrowers
    short: Pod, // debt and collat of ETH borrowers
} 

pub struct Stats {
    // TODO uncomment after fixed point compilation error is fixed
    // val_ether: UFP128, // $ value of ETH assets
    // stress_val: UFP128, //  $ value of the Solvency Pool in bad market stress, tail risk
    // avg_val: UFP128, // $ value of the Solvency Pool in average stress, 25-50 % price shock
    // stress_loss: UFP128, // % loss that Solvency pool would suffer in a bad stress event
    // avg_loss: UFP128, // % loss that Solvency pool would suffer in an avg stress event
    // premiums: UFP128, // $ amount of premiums borrower would pay in a year 
    // rate: UFP128, // annualized rate borrowers pay in periodic premiums 
    val_ether: u64,
    stress_val: u64,
    avg_val: u64,
    stress_loss: u64,
    avg_loss: u64,
    premiums: u64,
    rate: u64
}

pub struct PledgeStats {
    long: Stats,
    short: Stats,
    // TODO uncomment after fixed point compilation error is fixed
    // val_ether_sp: UFP128, // $ value of the ETH solvency deposit
    // val_total_sp: UFP128, // total $ value of val_eth + $QD solvency deposit
    val_ether_sp: u64,
    val_total_sp: u64
}

/**
 The first part is called "The Pledge". 
 The magician shows you something ordinary: 
 a deck of coins, a bird, or Johnny. You inspect it 
 to see if it is indeed real, unaltered, normal. 
 But of course...it probably isn't.
*/
pub struct Pledge { // each User pledges
    live: Pool, // collat in $QD or ETH
    
    // TODO save original pledge balance,
    // do not keep updating it until after 
    // the balance has been withdrawn fully
    
    // TODO to_be_paid gets incremented on every borrow ??
    // this is paid from the body of the collateral 
    // ( coming from an external source )
    stats: PledgeStats, // risk management metrics
    ether: u64, // SolvencyPool deposit of ETH
    quid: u64, // SolvencyPool deposit of $QD
    
    // index_long: u64, // TODO should be tuple, first arg is primary index according to significant figures, second is according to CR
    // index_short: u64, // TODO should be tuple, first arg is primary index according to significant figures, second is according to CR
    // last_voted: u64, // timestamp
    
    // TODO do we need to save the vote for target itself?
    // if yes, this...must be tuple...
    // index 0 for sh0rt and 1 for 1ong
    // target_vote: u64, 
    
    // TODO optional feature
    // target_CR: u64, // CR to keep above, must be above 110; 
    // if above, then pledge automatically take more leverage
}

// used for weighted median rebalancer
pub struct Medianizer {
    done: bool, index: u64, // used for updating pledges 
    target: u64, // update precision
    scale: u64, // TODO precision
    sum_w_k: u64, // sum(W[0..k])
    k: u64, // approx. index of median (+/- 1)
    // TODO uncomment after fixed point compilation error is fixed
    // solvency: UFP128,
    solvency: u64
}

pub struct Crank {
    last_update: u64, // timestamp of last time Crank was updated
    price: u64, // timestamp of last time price was update
    vol: u64,
    last_oracle: u64, // timestamp of last Oracle update
    short: Medianizer,
    long: Medianizer
}

pub const NINE: u64 = 9_000_000_000;
pub const TEN: u64 = 10_000_000_000;
pub const CDF: u64 = 1_281_551_565;
pub const ONE: u64 = 1_000_000_000; // 9 digits of precision, same as ETH

pub const TWO: u64 = ONE * 2; 
pub const MIN_CR: u64 = 1_100_000_000;
pub const POINT_SIX: u64 = 600_000_000;

// pub const MIN_PER_CENT = UFP128::from_uint(42_000_000);
// pub const MAX_PER_CENT = UFP128::from_uint(333_000_000);

// pub const PI = UFP128::from_uint(3141592653);
// pub const TWO_PI = UFP128::from_uint(2 * 3141592653);
// pub const LN_TEN = UFP128::from_uint(2302585093);

pub const PERIOD: u64 = 1095; // = (365*24)/8h of dues 
pub const ONE_HOUR: u64 = 3600; // in secs
pub const EIGHT_HOURS: u64 = 28_800;

/**
pub const DOT_OH_NINE: u128 = 90_909_090_909_090_909_090_909;
pub const FEE: u128 = 9_090_909_090_909_090_909_090; // TODO votable FEE
pub const MIN_DEBT: u128 = 90_909_090_909_090_909_090_909_090;
*/

pub fn get_msg_sender_address_or_panic() -> Address {
    let sender: Result<Identity, AuthError> = msg_sender();
    if let Identity::Address(address) = sender.unwrap() {
       address
    } else {
       revert(42);
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

// TODO uncomment after fixed point compilation error is fixed
/**
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

// the natural logarithm of a negative number is undefined.
pub fn ln(x: UFP128) -> UFP128 { 
    let result = x.value.log(UFP128::from_uint(TEN).value) / LN_TEN.value;
    return UFP128::from(result.into());
}

pub fn NormalCDFInverse(p: UFP128) -> IFP256 {
    let one = UFP128::from_uint(ONE);
    // ln is undefined for x <= 0
    assert(p > UFP128::zero() && p < one);
    
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
        return neg_one * IFP256::from(
            RationalApproximation(n_unsigned.sqrt())
        );
    }
    else { // F^-1(p) = G^-1(1-p)
        let l = one - p;
        let n: IFP256 = neg_two * IFP256::from(ln(l));
        assert(n > IFP256::zero());
        let n_unsigned: UFP128 = n.into();
        return IFP256::from(
            RationalApproximation(n_unsigned.sqrt())
        );
    }
}

// calculate % loss given short Pledge's portfolio 
// volatility & the statistical assumption of normality
pub fn stress(avg: bool, sqrt_var: UFP128, short: bool) -> IFP256 { // max portfolio loss in %
    let one = UFP128::from_uint(ONE);
    let mut neg_one = IFP256::from(one);
    neg_one = neg_one.sign_reverse();
    
    let two = UFP128::from_uint(TWO);
    let ten = UFP128::from_uint(TEN); 
    let nine = UFP128::from_uint(NINE);
    
    let mut alpha = nine / ten; // 10% of the worst case scenarios
    let one_minus_alpha = IFP256::from(one - alpha);
    // if avg {
    //     alpha = one / two; // 50% of the avg case scenarios
    // }
    // let cdf = NormalCDFInverse(alpha); 
    // TODO this is hardcoded for efficiency
    let cdf = IFP256::from(UFP128::from_uint(1_281_551_565));
    let e1 = neg_one * (cdf * cdf) / IFP256::from(two); // TODO hardcode
    let mut e2 = (
        (
            IFP256::exp(e1) / IFP256::from(TWO_PI.sqrt())
        ) / one_minus_alpha
    ) * IFP256::from(sqrt_var);
    
    if short {
        return IFP256::exp(e2) - IFP256::from(one);
    } else {
        e2 *= neg_one;
        return neg_one * (IFP256::exp(e2) - IFP256::from(one));
    }
}

pub fn erfc(x: IFP256) -> IFP256 {
    let one = IFP256::from(UFP128::from_uint(ONE));
    let neg_x = x.sign_reverse();
    
    let A1 = IFP256::from(UFP128::from_uint(254829592));
    
    let a2 = UFP128::from_uint(284496736);
    let mut A2 = IFP256::from(a2);
    A2 = A2.sign_reverse();
    
    let A3 = IFP256::from(UFP128::from_uint(1421413741));
    
    let a4 = UFP128::from_uint(1453152027);
    let mut A4 = IFP256::from(a4);
    A4 = A4.sign_reverse();
    
    let A5 = IFP256::from(UFP128::from_uint(1061405429));
    let P = IFP256::from(UFP128::from_uint(327591100));

    let t = one / (one + P * x);
    let y = (
        (
            (
                ((A5 * t + A4) * t) + A3
            ) * t + A2
        ) * t + A1
    ) * t;
    one - y * IFP256::exp(neg_x * x)
}

// Used for pricing put & call options for borrowers contributing to the ActivePool
pub fn pricing(payoff: UFP128, scale: UFP128, val_crypto: UFP128, val_quid: UFP128, ivol: UFP128, short: bool) -> UFP128 {
    let iVol = IFP256::from(ivol);
    // let min_rate = MIN_PER_CENT * scale; // * calibrate

    let one = UFP128::from_uint(ONE);
    let mut neg_one = IFP256::from(one);
    neg_one = neg_one.sign_reverse();

    let two = UFP128::from_uint(TWO);
    let mut neg_two = IFP256::from(two);
    neg_two = neg_two.sign_reverse();
    
    let div = val_crypto / val_quid;
    let l_n = IFP256::from(ln(div));
    let d = (l_n + (iVol * iVol / neg_two)/* times calibrate */) / iVol; // * calibrate
    let D = d / IFP256::from(two.sqrt());
    
    if short { // erfc is used instead of normal distribution
        return (payoff * erfc(neg_one * D).underlying / two) / val_crypto;  
    } else { 
        return (payoff * erfc(D).underlying / two) / val_quid;
    }
    // rate *= calibrate; // TODO before returning
}
*/