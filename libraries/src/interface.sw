library;

pub mod imports;
use imports::*;

abi Quid {
    // getters just for frontend testing    
    #[storage(read)] fn get_live() -> Pool;
    #[storage(read)] fn get_deep() -> Pool;
    #[storage(read)] fn get_brood() -> Pod;

    // TODO create separate abi Info
    // e.g. https://github.com/FuelLabs/sway-applications/blob/master/fundraiser/project/contracts/fundraiser-contract/src/interface.sw#L105
    #[storage(read)] fn get_pledge_live(who: Address) -> Pool;
    #[storage(read)] fn get_pledge_brood(who: Address) -> Pod;
    
    #[payable]
    #[storage(read, write), payable] fn deposit(live: bool, long: bool);

    #[payable]
    #[storage(read, write)] fn borrow(amount: u64, short: bool); // return live

    #[storage(read, write)] fn withdraw(amt: u64, sp: bool, qd: bool);
    
    // use collateral to repay debt and withdraw remainder
    #[storage(read, write)] fn fold(short: bool); 

    #[payable] // as in thunderclap
    #[storage(read, write)] fn clap(who: Address); // liquidate

    // #[storage(read, write)] fn vote (bool: short, vote: u64); 
    
    #[storage(read, write)] fn update(); 

    // TODO these two have been decoupled from update() 
    // just for semantic purposes (to see if that fixes 
    // compiler error) they can be merged back unless
    // it's empirically better for parallel execution?
    #[storage(read, write)] fn update_longs(); 
    #[storage(read, write)] fn update_shorts(); 

    #[storage(read)] fn get_price() -> u64;
    // TODO uncomment these oracle update functions
    #[storage(read, write)] fn set_price(price: u64);
    // #[storage(read, write)] fn set_vol(vol: u64);

    // TODO
    // for more production-quality testing with Redstone
    // https://docs.redstone.finance/docs/smart-contract-devs/custom-urls
    // use TAAPI pro API key 
    // https://github.com/redstone-finance/redstone-oracles-monorepo/tree/main/packages/fuel-connector/sway
}