# wowser

a webkit browser for macos that'll make you say "wow, the perfect place for all my stuff!"

## what's in it

**spaces for your projects.** each project (home, work, taxes, that apartment hunt…) gets its own space with its own tabs. ai picks an emoji and color for it. give a space a coding folder and it gets vs code, a terminal and a file browser too. drag any image into the sidebar to make it the space's background.

**bring your stuff over.** import logins, history and cookies from chrome-family browsers or safari. each import becomes its own space, with your top sites pinned as faves. passwords come along via an exported .csv.

**ai built in.** hook up claude, then ask your agent stuff right from the command bar like a web search, or click the wowie icon in the toolbar to ask about whatever page you're on. you can even ask it to restyle a page or change how it behaves. it also installs the wowser mcp into claude code, so `claude` in any terminal can drive the browser.

**goodies** (toggle them in settings):
- ad blocker
- auto dark mode for sites that don't have one
- memory — lets your ai full-text search your browsing activity
- nightly tab cleanup — tabs you haven't touched in a while move to old tabs
- https capture — lets the agent read your api traffic and talk to apis for you (*very* experimental)

**neat tricks:**
- option-click a link to open it in a split
- ⌘T → new terminal, or new vs code, right in a tab
- swipe down with three fingers (or ⌘E) to cycle through recent tabs

## heads up

- very experimental
- no passkeys
- some sites don't work
- not security-tested

## hacking on it

most code lives in the cross-platform `Wowser/Core` swift package (state, web stuff, ui); mac-specific bits are in the main xcode project. state lives in `BrowserStore`, which wraps a value-type `BrowserState`, and views observe it through small equatable snapshots. see `CLAUDE.md` for the full rundown.

build with xcode, or `swift build` from `Wowser/Core/`. keep both green.

## license

copyright © 2025 nate parrott.
