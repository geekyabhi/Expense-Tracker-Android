# Expensive

A Flutter expense tracker that works offline first and syncs to your own
Expenses server (the Django "Personal Shortcut" backend).

- **Add expenses fast:** from the app, from a floating **+** button that sits on
  the screen edge over every app, or from a popup that appears when you close
  an app you chose (for example a payment app). The popup puts that app's name
  in the expense's **Mode**.
- **One account, any sign-in:** email + password, phone + password or Google all
  open the same account. The token is kept in the Android keystore.
- **Offline first:** every expense is saved on the phone (SQLite). In **Auto**
  sync mode it is uploaded right after saving; if that fails it waits.
  In **Manual** mode nothing is sent until you select expenses and tap **Push**.
- **Full CRUD:** create, update (the same expense is updated, never
  duplicated), delete, and **Sync from server** (new expenses and website edits
  come in; expenses deleted on the server are only removed after you confirm).
- **Your own categories, modes and sources**, also learned from the server.
- **Event popups:** a Notion database holds events (Title, Subtitle,
  Date, Repeats). When you open the app, one of today's events pops up.

Android is the main target (the overlay features are Android-only).

## Run it

```bash
flutter pub get
flutter run          # a connected Android phone or an emulator
flutter test         # unit and widget tests
```

## Sign in and server

The app always talks to `https://personal.singhabhinav.in` (set in
`lib/config/app_config.dart`). Settings → Account & sync shows the account,
switches Auto/Manual and signs out.

- Signing in as a *different* account removes the expenses on the phone (they
  belong to the other account); signing back in as the same account keeps them,
  including ones not uploaded yet. Sign-out warns you first.
- **Google sign-in needs set-up outside the app:** the server must expose
  `POST /api/users/google/` (the deployed server does not yet), and Google Cloud
  needs an *Android* OAuth client for package `com.example.expense_tracker` with
  the SHA-1 of the signing key. The server verifies the token against the web
  client ID set in `lib/config/app_config.dart`.
- The server keeps one source per expense, so extra sources can't be stored; a
  multi-category expense is shown as "A, B" and re-sent as-is.

**Events database** (Settings → Events) stays on Notion, with its own token and ID. Nothing secret
is stored in this repository; they are kept on the phone only. Columns:

| Column | Type |
|---|---|
| Title, Subtitle | Text |
| Date | Date |
| Repeats | Select: Yearly, Monthly, Weekly or Daily (empty = once) |
| Type, Name | Select, Title (optional) |

Share the database with its Notion integration (••• → Connections).
**Save & test events** checks the token and the columns.

## Android permissions

The floating button and the close-an-app popup need *Display over other apps*;
the close-an-app popup also needs *Usage access*. On Samsung phones set the
app's battery to *Unrestricted*, or the background service may be stopped.
Settings → Permissions shows what is granted.

## Layout

- `lib/` – the Flutter app (`services/` for storage, the server and Notion, `screens/`)
- `android/app/src/main/kotlin/` – the overlay popup, floating button and the
  background service
- `test/` – tests (the server and Notion are faked with `MockClient`)

## Note for iCloud users

If this folder is under iCloud Drive's *Desktop & Documents*, iCloud can create
copies named `file 2` inside `build/` and break the Android build. Keep the
build output out of iCloud (`build` → `build.nosync`) or keep the project
outside synced folders. Those copies are git-ignored.
