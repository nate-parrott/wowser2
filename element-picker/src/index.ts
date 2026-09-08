import { PickerDebugUI } from './pickerDebugUI';
import { generateSelectorList, GenerateOptions, queryAll } from './selectorGen';
import { resolveAugmentedSelector } from './styleSelectors';

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
function selectorsForElementAtPoint(x: number, y: number, options: GenerateOptions = {}): SelectorDetails[] {
  const element = document.elementFromPoint(x, y);
  if (!element) {
    return [];
  }
  const selector = generateSelectorList(element as HTMLElement, options);
  const selectorDetails: SelectorDetails[] = selector.map((s) => {
    const matches = resolveAugmentedSelector(s);
    return {
      selector: s,
      matchCount: matches.length,
    };
  }
  );
  return selectorDetails
}

(window as any).__selectors_for_pt = selectorsForElementAtPoint;
(window as any).__sss_resolve = resolveAugmentedSelector;

