import { PickerDebugUI } from './pickerDebugUI';

// Initialize when the script loads
if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      new PickerDebugUI();
    });
  } else {
    new PickerDebugUI();
  }
}

console.log("Element Picker initialized");