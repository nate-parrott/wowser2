import { generateSelectorList } from "./selectorGen";

// Picker mode types
export enum PickerMode {
  IDLE = 'idle',
  PICKING = 'picking',
  PICKED = 'picked'
}

export interface PickerState {
  mode: PickerMode;
  targetElement: Element | null;
}

export class PickerDebugUI {
  private state: PickerState = {
    mode: PickerMode.IDLE,
    targetElement: null
  };
  
  private highlightBox: HTMLDivElement | null = null;
  private toolbar: HTMLDivElement | null = null;
  private pickButton: HTMLButtonElement | null = null;
  private statusDisplay: HTMLDivElement | null = null;
  
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
    
    // Assemble UI
    this.toolbar.appendChild(this.pickButton);
    this.toolbar.appendChild(this.statusDisplay);
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
        document.body.style.cursor = '';
        break;
        
      case PickerMode.PICKING:
        if (this.pickButton) this.pickButton.textContent = 'Cancel';
        if (this.statusDisplay) this.statusDisplay.textContent = 'Status: Picking (click on an element)';
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
    this.setMode(PickerMode.PICKED);
    // Get selectors
    generateSelectorList(element as HTMLElement);
  }
  
  private updateHighlightBox(rect: DOMRect): void {
    if (!this.highlightBox) return;
    
    this.highlightBox.style.top = `${rect.top}px`;
    this.highlightBox.style.left = `${rect.left}px`;
    this.highlightBox.style.width = `${rect.width}px`;
    this.highlightBox.style.height = `${rect.height}px`;
  }
}