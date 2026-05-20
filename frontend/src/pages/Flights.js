import React, { useState } from "react";
import axios from "axios";
import "./Flights.css";

const FLIGHTS_API_URL = process.env.REACT_APP_FLIGHTS_API_URL || "http://localhost:5001/flights";
const AIRLINES = ["AA", "DL", "UA"];

function Flights() {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [shouldRaise, setShouldRaise] = useState(false);

  const makeRequest = async (airline) => {
    const apiUrl = FLIGHTS_API_URL + `/${airline}` + (shouldRaise ? "?raise=500" : "");
    try {
      const response = await axios.get(apiUrl);
      setData(response.data);
      setError(null);
    } catch (error) {
      setError(error.message);
      setData(null);
    }
  }

  return (
    <div className="flights">
      Flights
      {AIRLINES.map((airline) => (
        <div key={airline}>
          <button className="app-btn" onClick={() => makeRequest(airline)}>Get {airline} Flights</button>
        </div>
      ))}
      <label className="should-raise-section">
        <span>Should raise error</span>
        <input type="checkbox" className="should-raise-checkbox" onChange={(e) => setShouldRaise(e.target.checked)} />
      </label>
      {error ? <p>Error: {error}</p> : null}
      {data ? <p>Response: {JSON.stringify(data)}</p> : null}
    </div>
  );
}

export default Flights;
