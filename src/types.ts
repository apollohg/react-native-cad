import type { Ref } from 'react';
import type { ViewProps } from 'react-native';

export type CADTool = 'select' | 'line' | 'rectangle' | 'arch' | 'freehand' | 'text' | 'eraser';
export type CADFeature = 'measurements' | 'dimensionEditing' | 'calibration' | 'grid' | 'snapping'
  | 'shapeRecognition' | 'panning' | 'zooming' | 'selectionMovement' | 'selectionResizing'
  | 'deletion' | 'duplication' | 'clearing' | 'history' | 'strokeStyling' | 'textStyling'
  | 'inkStyling' | 'pencilShortcuts';
export type CADControl = 'strokeColor' | 'lineWidth' | 'fill' | 'pressure' | 'widthScaling'
  | 'textColor' | 'fontFamily' | 'fontSize' | 'snapToGrid' | 'gridSpacing' | 'snapDistance'
  | 'undo' | 'redo' | 'delete' | 'duplicate' | 'calibrate' | 'zoomToFit' | 'clear';
export interface CADColor { red: number; green: number; blue: number; alpha: number }
export interface CADControlRange { bounds: [number, number]; step: number }
export interface CADConfiguration {
  enabledTools?: CADTool[];
  enabledFeatures?: CADFeature[];
  showsSnapGuides?: boolean;
  showsSelection?: boolean;
  showsEraserTarget?: boolean;
  controls?: {
    visibleTools?: CADTool[];
    visibleControls?: CADControl[];
    lineWidth?: CADControlRange;
    fontSize?: CADControlRange;
    gridSpacing?: CADControlRange;
    snapDistance?: CADControlRange;
    fontFamilies?: string[];
    buttonAppearance?: 'bordered' | 'borderless' | 'prominent';
    confirmsClear?: boolean;
  };
  measurements?: {
    axes?: ('horizontal' | 'vertical')[];
    roles?: ('element' | 'gap' | 'merged' | 'overall')[];
    showsExtensionLines?: boolean;
    allowsHiding?: boolean;
    unit?: 'millimeters' | 'centimeters' | 'meters' | 'inches' | 'feet';
    fractionDigits?: number;
  };
}
export interface CADDimensionStyle {
  labelFontSize?: number;
  labelPadding?: number;
  extensionOpacity?: number;
  extensionLineWidthScale?: number;
  edgeInset?: number;
  laneGap?: number;
  labelGap?: number;
  extensionGap?: number;
  extensionOvershoot?: number;
  terminatorHalfLength?: number;
  labelColor?: CADColor | null;
  labelBackground?: CADColor | null;
  extensionColor?: CADColor | null;
}
export interface CADTheme {
  dimensionStyle?: CADDimensionStyle;
  controlTint?: CADColor | null;
  inactiveToolTint?: CADColor | null;
  background?: CADColor;
  grid?: CADColor;
  stroke?: CADColor;
  selection?: CADColor;
  guides?: CADColor;
  gridMajor?: CADColor;
  axis?: CADColor;
  selectionHandleFill?: CADColor;
  eraserTarget?: CADColor;
  dimensions?: CADColor;
  gridMinorDashPattern?: number[];
  selectionDashPattern?: number[];
  guideDashPattern?: number[];
  controlSpacing?: number;
  gridLineWidth?: number;
  gridMajorLineWidth?: number;
  axisLineWidth?: number;
  selectionLineWidth?: number;
  dimensionLineWidth?: number;
  handleSize?: number;
  selectionOutset?: number;
  eraserTargetLineWidth?: number;
}
export interface CADOptions {
  configuration?: CADConfiguration;
  theme?: CADTheme;
  strokeStyle?: { stroke?: CADColor; fill?: CADColor | null; lineWidth?: number };
  inkConfiguration?: { pressureEnabled?: boolean; widthMode?: 'canvasScaled' | 'screenConstant' };
  textStyle?: { font?: { familyName?: string; pointSize?: number }; color?: CADColor };
  snapConfiguration?: { isEnabled?: boolean; screenThreshold?: number; gridSpacing?: number; snapToGrid?: boolean };
}
export interface CADDocumentChange {
  documentID: string;
  /** Decimal string: avoids losing precision for Swift UInt64 revisions. */
  revision: string;
  elementCount: number;
}
export interface CADError { operation: string; message: string }
export type CADRenderer = 'initializing' | 'metal' | 'coreGraphics';
export type CADCommand = 'undo' | 'redo' | 'clear' | 'deleteSelection' | 'duplicateSelection' | 'zoomToFit';
export interface CADCanvasRef {
  /** Serializes only the last committed document, never an in-progress stroke. */
  getDocument(): Promise<string>;
  /** Validates before replacing the document; resets selection and undo history. */
  loadDocument(json: string): Promise<void>;
  perform(command: CADCommand): Promise<boolean>;
  getRenderer(): Promise<CADRenderer>;
}
export interface CADCanvasProps extends ViewProps {
  ref?: Ref<CADCanvasRef>;
  options?: CADOptions;
  tool?: CADTool;
  onDocumentChange?: (event: { nativeEvent: CADDocumentChange }) => void;
  onError?: (event: { nativeEvent: CADError }) => void;
  onRendererChange?: (event: { nativeEvent: { renderer: CADRenderer } }) => void;
}
