/// The backend the app signs in to and syncs expenses with.
const String kDefaultServerUrl = 'https://personal.singhabhinav.in';

/// GOOGLE_WEB_CLIENT_ID of the backend. The app asks Google for its ID token with
/// this as the "server client ID", so the token's audience is one the backend
/// accepts. It is a public identifier, not a secret.
const String kGoogleWebClientId =
    '291160084770-1p13k42ipm1tteklode1b8nuo9t65q8a.apps.googleusercontent.com';

/// Event popups (a Notion events database) are switched off for now. The code
/// stays; set this to true to bring back the popup on opening the app and the
/// Settings → Events folder.
const kEventsEnabled = false;
