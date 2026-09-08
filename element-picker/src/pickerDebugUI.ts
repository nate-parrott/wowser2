import { generateSelectorList } from "./selectorGen";
import { resolveAugmentedSelector } from "./styleSelectors";

// Picker mode types
export enum PickerMode {
  IDLE = 'idle',
  PICKING = 'picking',
  PICKED = 'picked'
}

export interface PickerState {
  mode: PickerMode;
  targetElement: Element | null;
  selectors: { selector: string; matchCount: number }[];
  currentSelectorIndex: number;
}

export class PickerDebugUI {
  private state: PickerState = {
    mode: PickerMode.IDLE,
    targetElement: null,
    selectors: [],
    currentSelectorIndex: 0
  };

  private highlightBox: HTMLDivElement | null = null;
  private toolbar: HTMLDivElement | null = null;
  private pickButton: HTMLButtonElement | null = null;
  private statusDisplay: HTMLDivElement | null = null;
  private selectorPanel: HTMLDivElement | null = null;
  private selectorDisplay: HTMLDivElement | null = null;
  private sliderContainer: HTMLDivElement | null = null;
  private slider: HTMLInputElement | null = null;
  private matchCountDisplay: HTMLDivElement | null = null;
  private additionalElements: HTMLElement[] = [];

  constructor() {
    this.createUI();
  }

  private createUI(): void {
    // Create highlight box for hovering/selection
    this.highlightBox = document.createElement('div');
    this.highlightBox.style.position = 'fixed';
    this.highlightBox.style.border = '2px solid #4285f4';
    this.highlightBox.style.backgroundColor = 'rgba(66, 133, 244, 0.1)';
    this.highlightBox.style.zIndex = '9997';
    this.highlightBox.style.pointerEvents = 'none'; // Allow clicks to pass through
    this.highlightBox.style.display = 'none';
    document.body.appendChild(this.highlightBox);

    // Create toolbar
    this.toolbar = document.createElement('div');
    this.toolbar.style.position = 'fixed';
    this.toolbar.style.bottom = '20px';
    this.toolbar.style.right = '20px';
    this.toolbar.style.backgroundColor = 'rgba(0, 0, 0, 0.7)';
    this.toolbar.style.padding = '10px';
    this.toolbar.style.borderRadius = '5px';
    this.toolbar.style.boxShadow = '0 2px 10px rgba(0, 0, 0, 0.2)';
    this.toolbar.style.zIndex = '9999';
    this.toolbar.style.display = 'flex';
    this.toolbar.style.flexDirection = 'column';
    this.toolbar.style.gap = '8px';
    this.toolbar.style.maxWidth = '500px';

    // Create button
    this.pickButton = document.createElement('button');
    this.pickButton.textContent = 'Pick Element';
    this.pickButton.style.backgroundColor = '#4285f4';
    this.pickButton.style.color = 'white';
    this.pickButton.style.border = 'none';
    this.pickButton.style.padding = '8px 12px';
    this.pickButton.style.borderRadius = '4px';
    this.pickButton.style.cursor = 'pointer';
    this.pickButton.onclick = () => this.togglePickingMode();

    // Create status display
    this.statusDisplay = document.createElement('div');
    this.statusDisplay.style.color = 'white';
    this.statusDisplay.style.fontSize = '12px';
    this.statusDisplay.style.marginTop = '5px';
    this.statusDisplay.textContent = 'Status: Idle';

    // Create selector panel (initially hidden)
    this.selectorPanel = document.createElement('div');
    this.selectorPanel.style.marginTop = '10px';
    this.selectorPanel.style.padding = '8px';
    this.selectorPanel.style.backgroundColor = 'rgba(255, 255, 255, 0.1)';
    this.selectorPanel.style.borderRadius = '4px';
    this.selectorPanel.style.display = 'none';

    // Create selector display
    this.selectorDisplay = document.createElement('div');
    this.selectorDisplay.style.color = 'white';
    this.selectorDisplay.style.fontFamily = 'monospace';
    this.selectorDisplay.style.fontSize = '12px';
    this.selectorDisplay.style.padding = '8px';
    this.selectorDisplay.style.backgroundColor = 'rgba(0, 0, 0, 0.3)';
    this.selectorDisplay.style.borderRadius = '4px';
    this.selectorDisplay.style.marginBottom = '10px';
    this.selectorDisplay.style.wordBreak = 'break-all';
    this.selectorDisplay.style.width = '300px';
    this.selectorDisplay.style.maxHeight = '60px';
    this.selectorDisplay.style.overflow = 'auto';

    // Create match count display
    this.matchCountDisplay = document.createElement('div');
    this.matchCountDisplay.style.color = 'white';
    this.matchCountDisplay.style.fontSize = '12px';
    this.matchCountDisplay.style.marginBottom = '8px';

    // Create slider container
    this.sliderContainer = document.createElement('div');
    this.sliderContainer.style.display = 'flex';
    this.sliderContainer.style.flexDirection = 'column';
    this.sliderContainer.style.width = '100%';

    // Create slider labels
    const sliderLabels = document.createElement('div');
    sliderLabels.style.display = 'flex';
    sliderLabels.style.justifyContent = 'space-between';
    sliderLabels.style.color = 'white';
    sliderLabels.style.fontSize = '10px';
    sliderLabels.style.marginBottom = '4px';

    const uniqueLabel = document.createElement('span');
    uniqueLabel.textContent = 'More Unique';

    const genericLabel = document.createElement('span');
    genericLabel.textContent = 'More Generic';

    sliderLabels.appendChild(uniqueLabel);
    sliderLabels.appendChild(genericLabel);

    // Create slider
    this.slider = document.createElement('input');
    this.slider.type = 'range';
    this.slider.min = '0';
    this.slider.max = '0';
    this.slider.value = '0';
    this.slider.style.width = '100%';
    this.slider.style.accentColor = '#4285f4';
    this.slider.oninput = () => this.updateSelectorBySlider();

    // Assemble UI
    this.sliderContainer.appendChild(sliderLabels);
    this.sliderContainer.appendChild(this.slider);

    this.selectorPanel.appendChild(this.selectorDisplay);
    this.selectorPanel.appendChild(this.matchCountDisplay);
    this.selectorPanel.appendChild(this.sliderContainer);

    this.toolbar.appendChild(this.pickButton);
    this.toolbar.appendChild(this.statusDisplay);
    this.toolbar.appendChild(this.selectorPanel);
    document.body.appendChild(this.toolbar);

    // Initialize event listeners
    this.initEvents();
  }

  private initEvents(): void {
    // Mouse move event for tracking hover
    document.addEventListener('mousemove', (e) => {
      if (this.state.mode === PickerMode.PICKING) {
        const element = document.elementFromPoint(e.clientX, e.clientY);
        if (element && element !== this.highlightBox && element !== this.toolbar &&
            !this.toolbar?.contains(element)) {
          this.highlightElement(element);
        }
      }
    });

    // Click event for selection
    document.addEventListener('click', (e) => {
      if (this.state.mode === PickerMode.PICKING) {
        e.preventDefault();
        e.stopPropagation();

        const element = document.elementFromPoint(e.clientX, e.clientY);
        if (element && element !== this.highlightBox && element !== this.toolbar &&
            !this.toolbar?.contains(element)) {
          this.selectElement(element);
        }
      }
    });

    // Listen for escape key to cancel picking
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.state.mode === PickerMode.PICKING) {
        this.setMode(PickerMode.IDLE);
      }
    });
  }

  private togglePickingMode(): void {
    if (this.state.mode === PickerMode.IDLE) {
      this.setMode(PickerMode.PICKING);
    } else {
      this.setMode(PickerMode.IDLE);
    }
  }

  private setMode(mode: PickerMode): void {
    this.state.mode = mode;

    switch (mode) {
      case PickerMode.IDLE:
        if (this.pickButton) this.pickButton.textContent = 'Pick Element';
        if (this.statusDisplay) this.statusDisplay.textContent = 'Status: Idle';
        if (this.highlightBox) this.highlightBox.style.display = 'none';
        if (this.selectorPanel) this.selectorPanel.style.display = 'none';
        this.clearHighlightedElements();
        document.body.style.cursor = '';
        break;

      case PickerMode.PICKING:
        if (this.pickButton) this.pickButton.textContent = 'Cancel';
        if (this.statusDisplay) this.statusDisplay.textContent = 'Status: Picking (click on an element)';
        if (this.selectorPanel) this.selectorPanel.style.display = 'none';
        this.clearHighlightedElements();
        document.body.style.cursor = 'crosshair';
        break;

      case PickerMode.PICKED:
        if (this.pickButton) this.pickButton.textContent = 'Pick Again';
        if (this.statusDisplay) {
          const element = this.state.targetElement;
          const tagName = element?.tagName.toLowerCase();
          const id = element?.id ? `#${element.id}` : '';
          const classes = element?.className ? `.${element.className.split(' ').join('.')}` : '';
          this.statusDisplay.textContent = `Selected: ${tagName}${id}${classes}`;
        }
        if (this.selectorPanel) this.selectorPanel.style.display = 'block';
        document.body.style.cursor = '';
        break;
    }
  }

  private highlightElement(element: Element): void {
    if (!this.highlightBox) return;

    const rect = element.getBoundingClientRect();
    this.updateHighlightBox(rect);
    this.highlightBox.style.display = 'block';
  }

  private selectElement(element: Element): void {
    this.state.targetElement = element;
    const rect = element.getBoundingClientRect();
    this.updateHighlightBox(rect);

    // Generate selectors with match counts
    this.generateSelectors(element as HTMLElement);

    this.setMode(PickerMode.PICKED);
  }

  private updateHighlightBox(rect: DOMRect): void {
    if (!this.highlightBox) return;

    this.highlightBox.style.top = `${rect.top}px`;
    this.highlightBox.style.left = `${rect.left}px`;
    this.highlightBox.style.width = `${rect.width}px`;
    this.highlightBox.style.height = `${rect.height}px`;
  }

  private generateSelectors(element: HTMLElement): void {
    // Get raw selectors
    const selectorStrings = generateSelectorList(element, { augmented: document.body.classList.contains("picker-test-augmented") });

    // Create selector objects with match counts
    this.state.selectors = selectorStrings.map(selector => {
      const matchCount = resolveAugmentedSelector(selector).length;
      return { selector, matchCount };
    });

    // Sort by match count (ascending)
    this.state.selectors.sort((a, b) => a.matchCount - b.matchCount);

    // Update slider range
    if (this.slider && this.state.selectors.length > 0) {
      this.slider.min = '0';
      this.slider.max = (this.state.selectors.length - 1).toString();
      this.slider.value = '0';
      this.state.currentSelectorIndex = 0;

      // Display the first (most unique) selector
      this.updateSelectorDisplay();
    }
  }

  private updateSelectorBySlider(): void {
    if (!this.slider) return;

    const index = parseInt(this.slider.value, 10);
    if (index >= 0 && index < this.state.selectors.length) {
      this.state.currentSelectorIndex = index;
      this.updateSelectorDisplay();
    }
  }

  private updateSelectorDisplay(): void {
    if (!this.selectorDisplay || !this.matchCountDisplay) return;

    const { selector, matchCount } = this.state.selectors[this.state.currentSelectorIndex];

    // Update selector text
    this.selectorDisplay.textContent = selector;

    // Update match count
    this.matchCountDisplay.textContent = `Matches: ${matchCount} element${matchCount !== 1 ? 's' : ''}`;

    // Highlight matching elements
    this.highlightMatchingElements(selector);
  }

  private highlightMatchingElements(selector: string): void {
    // Clear previous highlights
    this.clearHighlightedElements();

    // Find all matching elements
    const matches = resolveAugmentedSelector(selector);

    // Highlight each match
    matches.forEach((element) => {
      if (element === this.state.targetElement) return; // Skip the selected element

      const highlight = document.createElement('div');
      highlight.style.position = 'absolute';
      highlight.style.border = '2px dashed orange';
      highlight.style.backgroundColor = 'rgba(255, 165, 0, 0.1)';
      highlight.style.zIndex = '9996';
      highlight.style.pointerEvents = 'none';

      const rect = element.getBoundingClientRect();
      highlight.style.top = `${window.scrollY + rect.top}px`;
      highlight.style.left = `${window.scrollX + rect.left}px`;
      highlight.style.width = `${rect.width}px`;
      highlight.style.height = `${rect.height}px`;

      document.body.appendChild(highlight);
      this.additionalElements.push(highlight);
    });
  }

  private clearHighlightedElements(): void {
    // Remove all additional highlight elements
    this.additionalElements.forEach(element => {
      element.remove();
    });
    this.additionalElements = [];
  }
}