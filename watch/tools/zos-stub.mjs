// Zepp OS, as far as the previews need it: modules that record the widgets a
// page or the face makes (watch/tools/preview.mjs runs them, preview.py draws).

export const widgets = []
let nextId = 1

function make(type, props) {
  const w = { id: nextId++, type, props: { ...props }, visible: true, listeners: {} }
  w.setProperty = (key, value) => {
    if (key === 'more') Object.assign(w.props, value)
    else if (key === 'visible') w.visible = !!value
    else w.props[key] = value
  }
  w.getProperty = (key) => w.props[key]
  w.addEventListener = (name, fn) => (w.listeners[name] = fn)
  w.removeEventListener = () => {}
  widgets.push(w)
  return w
}

export const ui = {
  widget: new Proxy({}, { get: (_, name) => String(name) }),
  prop: { TEXT: 'text', COLOR: 'color', VISIBLE: 'visible', MORE: 'more', X: 'x', Y: 'y', W: 'w', H: 'h', SRC: 'src', START_ANGLE: 'start_angle', END_ANGLE: 'end_angle', LINE_WIDTH: 'line_width' },
  align: { LEFT: 'left', RIGHT: 'right', CENTER_H: 'center', TOP: 'top', BOTTOM: 'bottom', CENTER_V: 'middle' },
  text_style: { WRAP: 'wrap', ELLIPSIS: 'ellipsis', NONE: 'none', CHAR_WRAP: 'wrap' },
  event: { CLICK_DOWN: 'down', CLICK_UP: 'up', MOVE: 'move' },
  createWidget: (type, props) => make(type, props),
  deleteWidget: (w) => {
    const i = widgets.indexOf(w)
    if (i >= 0) widgets.splice(i, 1)
  },
}

export const timeNow = { value: new Date(2026, 9, 17, 20, 37) }
