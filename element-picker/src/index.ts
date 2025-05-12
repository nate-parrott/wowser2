import { PickerDebugUI } from './pickerDebugUI';
import { generateSelectorList } from './selectorGen';

// Initialize when the script loads
if (typeof document !== 'undefined') {
  if (document.body.classList.contains('picker-test')) {
    new PickerDebugUI();
  }
}

interface SelectorDetails {
  selector: string;
  matchCount: number;
}
function selectorsForElementAtPoint(x: number, y: number): SelectorDetails[] {
  const element = document.elementFromPoint(x, y);
  if (!element) {
    return [];
  }
  const selector = generateSelectorList(element as HTMLElement);
  const selectorDetails: SelectorDetails[] = selector.map((s) => {
    const matches = document.querySelectorAll(s);
    return {
      selector: s,
      matchCount: matches.length,
    };
  }
  );
  return selectorDetails
}

(window as any).__selectors_for_pt = selectorsForElementAtPoint;

