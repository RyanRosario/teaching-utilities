// app.js
const express = require('express');
const path = require('path');
const config = require('./config.json');

// Create Express app
const app = express();

// Middleware
app.use(express.json());
app.use(express.static('public'));

// Import routes
const resetRouter = require('./routes/resetRoutes');

// Use routes
app.use('/reset', resetRouter);

const PORT = process.env.PORT || config.port || 3000;
app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
