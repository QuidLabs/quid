library;

pub mod imports;

abi Quid {
    #[storage(read, write), payable] fn deposit (live: bool, long: bool);

    #[storage(read, write)] fn withdraw (amt: u64, sp: bool, qd: bool);
    // use collateral to repay debt and withdraw remainder
    #[storage(read, write)] fn fold (short: bool); 

    // #[storage(read, write)] fn clap (who: Address); // liquidate
    
    #[storage(read, write)] fn update (); 
}