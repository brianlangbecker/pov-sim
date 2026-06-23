import { Route } from 'react-router-dom';
import { FaroRoutes } from '@grafana/faro-react';
import './App.css';
import Home from './pages/Home';
import Airlines from './pages/Airlines';
import Flights from './pages/Flights';
import Navigation from './components/Navigation';

function App() {
  return (
    <div className="App">
      <header className="App-header">
        <Navigation />
        <FaroRoutes>
          <Route path="/" element={<Home />} />
          <Route path="/flights" element={<Flights />} />
          <Route path="/airlines" element={<Airlines />} />
        </FaroRoutes>
      </header>
    </div>
  );
}

export default App;
