# GitHub App Setup for gh-discuss

By default, posts appear as your personal GitHub account. To post as a bot instead:

## 1. Create a GitHub App

Go to https://github.com/settings/apps/new:
- **Name**: e.g. `workspaces-agents` (posts will show as `workspaces-agents[bot]`)
- **Webhook**: Uncheck "Active" (not needed)
- **Repository permissions**: Discussions → Read & write
- **Where can this app be installed?**: Only on this account
- Click "Create GitHub App", note the **App ID**
- Generate a **private key** (downloads a `.pem` file)

## 2. Install the App

From the app settings page, click "Install App" and select the target repository.
Note the **Installation ID** from the URL: `https://github.com/settings/installations/INSTALLATION_ID`

## 3. Store Credentials

```bash
mkdir -p ~/.config/gh-discuss
echo 'YOUR_APP_ID' > ~/.config/gh-discuss/app-id
echo 'YOUR_INSTALLATION_ID' > ~/.config/gh-discuss/installation-id
cp ~/Downloads/your-app.*.pem ~/.config/gh-discuss/app.pem
chmod 600 ~/.config/gh-discuss/app.pem
```

Or use environment variables: `GH_DISCUSS_APP_ID`, `GH_DISCUSS_INSTALLATION_ID`, `GH_DISCUSS_PRIVATE_KEY_PATH`

## 4. Verify

```bash
gh-discuss.py setup
gh-discuss.py verify
```

If no credentials are found, the script falls back to personal `gh` CLI auth with a stderr notice.
