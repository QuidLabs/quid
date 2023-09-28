import React from 'react';
import logo from './logo.svg';
import './App.css';
import { useFuel } from './hooks/useFuel'
import { useIsConnected } from './hooks/useIsConnected';
import { Wallet } from "fuels"
// import { quid abi factory } from "./types"

function App() {
  const [fuel, notDetected] = useFuel();
  const [isConnected] = useIsConnected();
  // const myWallet = wallet.fromAddress("");
  // console.log("wallet address", myWallet.address.toB256())
  // in frontend folder do 
  // npx fuels typegen -i ../contracts/QD/out/debug/QD-abi.json -o ./src/types
  return (
    <div className="App">
      <header className="App-header">
        <img src={logo} className="App-logo" alt="logo" />
      </header>
      { fuel && (
          <div>
            <div>fuel is detected</div>
            { isConnected ? (
              <div> you are connected </div>
            ) : (
              <button onClick={() => fuel.connect()}>connect wallet</button>
            )}
          </div>
        )
      }
      {
        notDetected && (
          <div>fuel is NOT detected</div>
        )
      }
    </div>
  );
}

export default App;
