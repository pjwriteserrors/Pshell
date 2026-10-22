// The app keeps the connection to the PC for all its pages (lib/link.js).
import { createLink } from './lib/link.js'

App({
  globalData: { link: null },
  onCreate() {
    this.globalData.link = createLink()
    this.globalData.link.start()
  },
  onDestroy() {
    if (this.globalData.link) this.globalData.link.stop()
  },
})
