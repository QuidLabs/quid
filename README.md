# 👁‍🗨U!D

## Testing instructions

**Note: there are many TODOs in `main.sw`!**

#### step 0
run `npm install`  

cd `contracts/QD`
compile contract with `forc build` and run rust tests with `cargo test`

`cd` into frontend folder, and generate type bindings (the frontend requires these for communicating with the contract)  

`npx fuels typegen -i ../contracts/QD/out/debug/QD-abi.json -o ./src/types`

#### step 1
Download Fuel [Wallet](https://wallet.fuel.network/docs/install/)  

Make sure to set the network to http://localhost:4000/graphql
It will only work when you actually run the local node  
or use testnet

#### step 2  load up some users with initial balances
Inside `App.tsx` insert the address from inside your Fuel Wallet (string starts with fuel...)  
or use the one from `forc wallet accounts`  
it will tell you to init if first time
`forc wallet new`  
`forc wallet account new`  


### `npm start`  

See the console.log output for your hex address  

To run a local node with persistence, you must [configure](https://docs.fuel.network/guides/running-a-node/running-a-local-node/) a chainConfig.json file.  

Inside the .json  
Set initial_state --> coins --> owner to equal the address in your Fuel Wallet (hex version)  

You will need to repeat the above steps several times (while adding accounts inside the Fuel wallet...by clicking the 'Change' dropdown)  

### `fuel-core run --db-type in-memory --chain ./chainConfig.json`  
Run this command from the root directory (not frontend folder, unlike npm start)  

### run `forc deploy --unsigned` from the contracts folder
Add the contract id returned by this command to App.tsx  

or `forc deploy --testnet`  
in a separate terminal window use the provided transaction id and account from forc-wallet  
to sign with `forc-wallet sign --acccount 0 tx-id ...`  
paste the result into the deployment terminal window  