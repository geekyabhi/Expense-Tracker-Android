# Expensive

A Flutter expense tracker that works offline first and syncs to Notion.

- **Add expenses fast:** from the app, from a floating **+** button that sits on
  the screen edge over every app, or from a popup that appears when you close
  an app you chose (for example a payment app). The popup puts that app's name
  in the expense's **Mode**.
- **Offline first:** every expense is saved on the phone (SQLite). In **Auto**
  sync mode it is pushed to Notion right after saving; if that fails it waits.
  In **Manual** mode nothing is sent until you select expenses and tap **Push**.
- **Full CRUD with Notion:** create, update (the same page is updated, never
  duplicated), read (**Sync from Notion** imports rows you don't have yet) and
  delete (the Notion page is archived).
- **Your own categories, modes and sources**, saved on the phone.
- **Event popups:** a second Notion database holds events (Title, Subtitle,
  Date, Repeats). When you open the app, one of today's events pops up.

Android is the main target (the overlay features are Android-only).

## Run it

```bash
flutter pub get
flutter run          # a connected Android phone or an emulator
flutter test         # unit and widget tests
```

## Connect Notion

Nothing secret is stored in this repository. Open **Settings** in the app and
paste each token and database ID there. They are kept on the phone only
(unencrypted app storage), so treat the phone as the trust boundary.

**Expenses database** (Settings → Expenses & Notion) needs these columns:

| Column | Type |
|---|---|
| Expense | Title |
| Amount | Number |
| Date | Date |
| Category, Source, Mode | Multi-select |
| Processed | Checkbox (read-only here; drives the green/red rows) |

**Events database** (Settings → Events) has its own token and ID, with:

| Column | Type |
|---|---|
| Title, Subtitle | Text |
| Date | Date |
| Repeats | Select: Yearly, Monthly, Weekly or Daily (empty = once) |
| Type, Name | Select, Title (optional) |

Share each database with its own Notion integration (••• → Connections).
**Save & test** in each folder checks the token and the columns.

## Android permissions

The floating button and the close-an-app popup need *Display over other apps*;
the close-an-app popup also needs *Usage access*. On Samsung phones set the
app's battery to *Unrestricted*, or the background service may be stopped.
Settings → Permissions shows what is granted.

## Layout

- `lib/` – the Flutter app (`services/` for storage and Notion, `screens/`)
- `android/app/src/main/kotlin/` – the overlay popup, floating button and the
  background service
- `test/` – tests (Notion calls are faked with `MockClient`)

## Note for iCloud users

If this folder is under iCloud Drive's *Desktop & Documents*, iCloud can create
copies named `file 2` inside `build/` and break the Android build. Keep the
build output out of iCloud (`build` → `build.nosync`) or keep the project
outside synced folders. Those copies are git-ignored.
