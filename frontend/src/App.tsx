import React from 'react';
import logo from './logo.svg';
import './App.css';
import { useFuel } from './hooks/useFuel'

function App() {
  const [fuel, notDetected] = useFuel()
  return (
    <div className="App">
      <header className="App-header">
        <img src={logo} className="App-logo" alt="logo" />
      </header>
      { fuel && (
          <div>fuel is detected</div>
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
