// Minimal bundle entry: exposes the augmented-selector resolver for Swift's
// AugmentedSelector.matchesJS(for:) to inline into pages that don't have the
// full element picker loaded.
import { resolveAugmentedSelector } from './styleSelectors';

(window as any).__sss_resolve = resolveAugmentedSelector;
