# Use the official Node.js image
FROM node:18-alpine

# Set the working directory inside the container
WORKDIR /app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy the rest of the application code
COPY . .

ARG REACT_APP_AIRLINES_API_URL=http://localhost:8080/airlines
ARG REACT_APP_FLIGHTS_API_URL=http://localhost:5001/flights
ENV REACT_APP_AIRLINES_API_URL=$REACT_APP_AIRLINES_API_URL
ENV REACT_APP_FLIGHTS_API_URL=$REACT_APP_FLIGHTS_API_URL

# Expose the port on which the app will run
EXPOSE 3000

# Start the React development server
CMD ["npm", "start"]
