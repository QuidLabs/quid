// import React from 'react';
// import logo from './logo.svg';
import './App.css';
import { useFuel } from './hooks/useFuel';
import { useIsConnected } from './hooks/useIsConnected';
import { Wallet } from 'fuels'

// TODO uncomment this after type generation
import { QDAbi__factory } from "./types"

function App() {
  const [fuel, notDetected] = useFuel();
  const [isConnected] = useIsConnected();
  
  // TODO we get this from fuel-core 
  const CONTRACT_ID = "0xe0767304c2b083731066c883df00b6253d35365fe298f0b43ae1ea5a34eaa794"

  // TODO replace with the address in your Fuel Wallet 
  const wallet = Wallet.fromAddress("fuel1n0t6gn0m8xwe6lmmgezm7cn79lmyltqfzspj80af0jzt98s0m3xsu4sz5f");
  console.log("address", wallet.address.toB256())
  // 0x9bd7a44dfb399d9d7f7b4645bf627e2ff64fac09140323bfa97c84b29e0fdc4d

  async function set_price() {
    var inputValue = (document.getElementById('priceInput') as HTMLInputElement).value;
    const account = await fuel.currentAccount();
    const wallet = await fuel.getWallet(account);
    const contract = QDAbi__factory.connect(CONTRACT_ID, wallet);
    let resp = await contract.functions
    .set_price(inputValue)
    // .txParams({ variableOutputs: 1}) // this indicates to expect a return from the function
    // .callParams({ // this indicates msg.value to attach
    //   forward: [amount, CONTRACT_ID],
    // })
    .call();
    console.log("RESPONSE:", resp.value)
  }

  return (
    <div className="App">
      { fuel && (
          <div>
            <div>fuel is detected</div>
            { isConnected ? (
              <div>
                <label>Enter a new price:</label>
                <input type="number" id="priceInput" required></input>
                <button onClick={set_price}>New Price</button>
              </div>
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
