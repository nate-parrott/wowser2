# Wowser2

A modern WebKit-based browser for macOS with a focus on productivity and performance.

## Features

- **Ad Blocking**: Built-in ad and cookie banner blocking
- **Dark Mode**: Automatic dark mode for websites that don't support it natively
- **Tab Management**: Split view tabs, tab organization, and profiles
- **Productivity Tools**: Project-based organization, archiving, and favorites
- **Modern UI**: Built with SwiftUI for a native macOS experience

## Architecture

Wowser2 is built with a clean, modern architecture:

- **Core Package**: Cross-platform Swift Package for browser functionality (iOS + macOS)
- **State Management**: Centralized store pattern with immutable state
- **UI Updates**: Efficient UI updates through snapshot pattern
- **Web Rendering**: Enhanced WebKit with additional features and customizations

## Development

The codebase is organized as follows:

- `Wowser/` - macOS application code
- `Wowser/Core/` - Cross-platform core functionality
  - `Data/` - State management and persistence
  - `Web/` - Web content handling and rendering
  - `UI/` - User interface components
  - `Adblock/` - Ad-blocking functionality
  - `Utils/` - Utility functions and extensions

## State Management

Wowser2 uses a centralized state management approach:

- `BrowserStore`: Singleton that manages browser state
- `BrowserState`: Immutable value type containing browser data
- Components observe state changes through snapshots to minimize UI updates

## License

Copyright © 2025 Nate Parrott