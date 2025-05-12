import { PickerDebugUI } from './pickerDebugUI';

// Initialize when the script loads
if (typeof document !== 'undefined') {
  if (document.body.classList.contains('picker-test')) {
    new PickerDebugUI();
  }
}
