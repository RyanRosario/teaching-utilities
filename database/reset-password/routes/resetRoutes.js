// routes/resetRoutes.js
const express = require('express');
const router = express.Router();
const { spawn } = require('child_process');
const crypto = require('crypto');
const nodemailer = require('nodemailer');
const path = require('path');
const config = require('../config.json');

// Database connection
const { Pool } = require('pg');
const dbPool = new Pool(config.database);

// Store for reset tokens
const tokens = new Map();

// Email transporter
const transporter = nodemailer.createTransport(config.email);

// Serve the password reset request form
router.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, '../public/reset/index.html'));
});

// Serve the password change form
router.get('/change', (req, res) => {
    res.sendFile(path.join(__dirname, '../public/reset/change.html'));
});

// Helper function to get email from database
async function getEmailForUsername(username) {
    try {
        const { rows } = await dbPool.query(
            'SELECT email_address FROM students WHERE username = $1',
            [username]
        );
        return rows.length > 0 ? rows[0].email_address : null;
    } catch (error) {
        console.error('Database error:', error);
        return null;
    }
}

// Helper function to update MongoDB SCRAM password
async function updateMongoPassword(username, newPassword) {
    return new Promise((resolve, reject) => {
        // Skip if MongoDB config not present
        if (!config.mongodb || !config.mongodb.adminUser || !config.mongodb.adminPass) {
            console.log('MongoDB config not found, skipping MongoDB password update');
            return resolve();
        }

        const { adminUser, adminPass, host = '127.0.0.1', port = 27017, caFile = '/etc/mongodb/ssl/ca.pem' } = config.mongodb;

        // Escape special characters in password for JavaScript string
        const escapedPassword = newPassword.replace(/\\/g, '\\\\').replace(/'/g, "\\'");

        // Update password in user's own database (where SCRAM user was created)
        const updateCmd = `
            try {
                db.getSiblingDB('${username}').updateUser('${username}', { pwd: '${escapedPassword}' });
                print('Password updated successfully');
            } catch(e) {
                // User might not exist in MongoDB yet
                print('MongoDB user update skipped: ' + e.message);
            }
        `;

        const mongosh = spawn('mongosh', [
            '--quiet',
            `mongodb://${adminUser}:${adminPass}@${host}:${port}/admin?tls=true&tlsCAFile=${caFile}&authSource=admin`,
            '--eval', updateCmd
        ]);

        let stdout = '';
        let stderr = '';

        mongosh.stdout.on('data', (data) => { stdout += data.toString(); });
        mongosh.stderr.on('data', (data) => { stderr += data.toString(); });

        mongosh.on('close', (code) => {
            if (code === 0) {
                resolve();
            } else {
                reject(new Error(`mongosh exited with code ${code}: ${stderr}`));
            }
        });

        mongosh.on('error', (err) => {
            reject(err);
        });
    });
}

// Handle password reset request
router.post('/request', async (req, res) => {
    try {
        const { username } = req.body;
        if (!username) {
            return res.status(400).json({ error: 'Username is required' });
        }

        // Get email from database
        const email = await getEmailForUsername(username);

        if (!email) {
            return res.json({ message: 'If the username exists, reset instructions have been sent' });
        }

        // Generate secure token
        const resetToken = crypto.randomBytes(32).toString('hex');
        tokens.set(resetToken, {
            username,
            expires: Date.now() + 24 * 60 * 60 * 1000 // 24 hours
        });

        // Create reset URL
        const resetUrl = `${config.appUrl}/reset/change?token=${resetToken}`;

        // Send email
        await transporter.sendMail({
            from: config.email.from,
            to: email,
            subject: `${config.courseName} Password Reset Request`,
            html: `
                <p>You requested a password reset for username: <strong>${username}</strong></p>
                <p>Click <a href="${resetUrl}">here</a> to reset your password.</p>
                <p>This link will expire in 24 hours.</p>
                <p>If you did not request this reset, please ignore this email.</p>
            `
        });

        res.json({ message: 'Reset instructions sent to your email if your username exists' });

    } catch (error) {
        console.error('Reset request error:', error);
        res.status(500).json({ error: 'Failed to process reset request' });
    }
});

// Handle password change
router.post('/new', (req, res) => {
    try {
        const { token, newPassword } = req.body;

        // Validate password length
        if (!newPassword || newPassword.length < 8) {
            return res.status(400).json({ error: 'Password must be at least 8 characters long' });
        }

        // Validate token
        const tokenData = tokens.get(token);
        if (!tokenData || Date.now() > tokenData.expires) {
            return res.status(400).json({ error: 'Invalid or expired token' });
        }

        // Get email for confirmation
        getEmailForUsername(tokenData.username).then(email => {
            // Execute passwd command
            const passwd = spawn('sudo', ['passwd', tokenData.username]);
            let stderrOutput = '';
            let stdoutOutput = '';

            passwd.stdout.on('data', (data) => {
                const output = data.toString();
                stdoutOutput += output;
                console.log('passwd output:', output);
            });

            passwd.stderr.on('data', (data) => {
                const output = data.toString();
                stderrOutput += output;
                console.log('passwd stderr:', output);

                if (output.includes('New password:') || output.includes('Retype')) {
                    passwd.stdin.write(`${newPassword}\n`);
                }
            });

            passwd.on('close', (code) => {
                if (code === 0) {
                    // Also update MongoDB SCRAM password
                    updateMongoPassword(tokenData.username, newPassword)
                        .then(() => {
                            console.log(`MongoDB password updated for ${tokenData.username}`);
                        })
                        .catch(err => {
                            console.error(`Failed to update MongoDB password for ${tokenData.username}:`, err);
                            // Continue anyway - Unix password was changed successfully
                        });

                    // Send confirmation email if we have the email address
                    if (email) {
                        transporter.sendMail({
                            from: config.email.from,
                            to: email,
                            subject: `${config.courseName} Password Change Confirmation`,
                            html: `
                                <p>Your password for username <strong>${tokenData.username}</strong> has been successfully changed.</p>
                                <p>This password works for both SSH/terminal access and MongoDB (DataGrip) connections.</p>
                                <p>If you did not make this change, please contact the course staff immediately.</p>
                            `
                        })
                            .then(() => {
                                tokens.delete(token);
                                res.json({ message: 'Password successfully changed. Have a nice day!' });
                            })
                            .catch(error => {
                                console.error('Email error:', error);
                                tokens.delete(token);
                                res.json({ message: 'Password successfully changed, but confirmation email failed' });
                            });
                    } else {
                        tokens.delete(token);
                        res.json({ message: 'Password successfully changed' });
                    }
                } else {
                    // Parse error messages from passwd
                    let errorMessage = 'Failed to change password';

                    if (stderrOutput.includes('too simple') || stderrOutput.includes('too short')) {
                        errorMessage = 'Password is too simple or too short. Please choose a stronger password.';
                    } else if (stderrOutput.includes('based on a dictionary word')) {
                        errorMessage = 'Password is based on a dictionary word. Please choose a different password.';
                    } else if (stderrOutput.includes('based on your username')) {
                        errorMessage = 'Password is too similar to your username. Please choose a different password.';
                    } else if (stderrOutput.includes('palindrome')) {
                        errorMessage = 'Password is a palindrome. Please choose a different password.';
                    } else if (stderrOutput.includes('case changes only')) {
                        errorMessage = 'Password only differs by case. Please choose a different password.';
                    } else if (stderrOutput.includes('similar to the old one')) {
                        errorMessage = 'Password is too similar to the old one. Please choose a different password.';
                    } else if (stderrOutput.includes('passwords do not match')) {
                        errorMessage = 'An error occurred during password change. Please try again.';
                    } else if (stderrOutput.trim()) {
                        errorMessage = stderrOutput.trim();
                    }

                    console.error('Password change failed:', stderrOutput);
                    res.status(400).json({ error: errorMessage });
                }
            });

            passwd.on('error', (error) => {
                console.error('Password change error:', error);
                res.status(500).json({ error: 'Failed to change password: ' + error.message });
            });
        });

    } catch (error) {
        console.error('Password reset error:', error);
        res.status(500).json({ error: 'Failed to reset password' });
    }
});

module.exports = router;
