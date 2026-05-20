import React, { useState } from "react";
import axios from "axios";
import "./Airlines.css";

const AIRLINES_API_URL = process.env.REACT_APP_AIRLINES_API_URL || "http://localhost:8080/airlines";

function Airlines() {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [shouldRaise, setShouldRaise] = useState(false);

  const makeRequest = async () => {
    const apiUrl = shouldRaise ? `${AIRLINES_API_URL}?raise=true` : AIRLINES_API_URL;
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
    <div className="airlines">
      Airlines
      <div>
        <button className="app-btn" onClick={makeRequest}>Get Airlines</button>
      </div>
      <label className="should-raise-section">
        <span>Should raise error</span>
        <input type="checkbox" className="should-raise-checkbox" onChange={(e) => setShouldRaise(e.target.checked)} />
      </label>
      {error ? <p>Error: {error}</p> : null}
      {data ? <p>Response: {JSON.stringify(data)}</p> : null}
    </div>
  );
}

export default Airlines;
