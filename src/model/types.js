// Geometry of the standard IDEF0 sheet, plus IDEF0 vocabulary constants.
// All model coordinates are in "sheet units"; the sheet is 1100 x 850
// (an 11x8.5 landscape page at 100 units per inch).

export const SHEET = { w: 1100, h: 850 };

/** Outer frame of the IDEF0 form. */
export const FRAME = { x: 24, y: 24, w: 1052, h: 802 };

/** Height of the header band (Used At / Author / Notes / Status / Context). */
export const HEADER_H = 92;
/** Height of the footer band (Node / Title / Number). */
export const FOOTER_H = 56;

/** The drawing area: everything the modeller may place boxes and arrows in. */
export const WORK = {
  x: FRAME.x + 16,
  y: FRAME.y + HEADER_H + 16,
  w: FRAME.w - 32,
  h: FRAME.h - HEADER_H - FOOTER_H - 32,
};
WORK.x2 = WORK.x + WORK.w;
WORK.y2 = WORK.y + WORK.h;

export const BOX_DEFAULT = { w: 190, h: 112 };
export const BOX_MIN = { w: 110, h: 70 };

export const SIDES = ['left', 'top', 'right', 'bottom'];

/** IDEF0 arrow roles, keyed by the side of the box they touch. */
export const SIDE_ROLE = { left: 'input', top: 'control', right: 'output', bottom: 'mechanism' };
export const SIDE_ICOM = { left: 'I', top: 'C', right: 'O', bottom: 'M' };
export const ROLE_LABEL = {
  input: 'Input', control: 'Control', output: 'Output',
  mechanism: 'Mechanism', call: 'Call', unknown: 'Unclassified',
};

/** FIPS 183 model status values. */
export const STATUS_VALUES = ['WORKING', 'DRAFT', 'RECOMMENDED', 'PUBLICATION'];

export const GLOSSARY_KINDS = ['activity', 'data', 'mechanism', 'other'];

/** How many boxes an IDEF0 decomposition diagram should contain. */
export const DECOMP_MIN = 3;
export const DECOMP_MAX = 6;

/** Length of the straight stub an arrow travels before it may turn. */
export const STUB = 22;
