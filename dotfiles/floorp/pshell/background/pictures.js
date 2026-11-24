// The pictures of a whole page (docs/browser.md "The Pshell menu"), beside
// bridge.js and sharing its scope (`COMMANDS`, `inTab`, `scriptable`):
// `pictures {tabId}` → { title, url, pictures: [{ src, alt, width, height }] }
// in the page's order, each at the largest size the page offers (srcset,
// a link around it to the picture itself, Reddit's and Imgur's originals);
// icons, avatars and pictures under 200 px go. A blob: picture is read in
// the page and comes as a data: URL. The shell (WebPictures.qml) downloads
// them; nothing of a private window is read.

function collectPictures() {
	const MIN = 200;
	const found = [];
	const seen = new Set();
	const picture = /\.(jpe?g|png|webp|gif|avif)(\?|#|$)/i;

	function absolute(url) {
		try {
			return new URL(url, location.href).href;
		} catch (error) {
			return "";
		}
	}

	// the biggest candidate of a srcset
	function largest(srcset) {
		let best = "", size = 0;
		for (const part of String(srcset || "").split(/,\s+(?=\S)/)) {
			const [url, descriptor] = part.trim().split(/\s+/);
			const value = parseFloat(descriptor || "1") * (/(\d+)w$/.test(descriptor || "") ? 1 : 1000);
			if (url && value >= size) {
				best = url;
				size = value;
			}
		}
		return best;
	}

	// the original behind a site's preview (Reddit, Imgur)
	function original(url) {
		try {
			const u = new URL(url);
			if (u.hostname === "preview.redd.it") return `https://i.redd.it${u.pathname.replace(/^\/[^/]*-(?=[a-z0-9]+\.\w+$)/i, "/")}`;
			if (u.hostname === "i.imgur.com") return url.replace(/^(https:\/\/i\.imgur\.com\/[A-Za-z0-9]{7})[sbtmlh]?(\.\w+).*$/, "$1$2");
		} catch (error) {}
		return url;
	}

	function add(url, alt, width, height) {
		url = absolute(url);
		if (!/^(https?|blob|data):/.test(url) || url.startsWith("data:image/svg") || /\.svg(\?|$)/i.test(url)) return;
		url = original(url);
		const key = url.replace(/[?#].*$/, "");
		if (seen.has(key)) return;
		seen.add(key);
		found.push({ src: url, alt: String(alt || "").trim().slice(0, 200), width: width || 0, height: height || 0 });
	}

	const nodes = [];
	// shadow roots that are open (Reddit's carousel lives in one)
	(function walk(root) {
		for (const node of root.querySelectorAll("*")) {
			if (node.tagName === "IMG") nodes.push(node);
			if (node.shadowRoot) walk(node.shadowRoot);
		}
	})(document);

	for (const img of nodes) {
		const rect = img.getBoundingClientRect();
		const width = img.naturalWidth || Number(img.getAttribute("width")) || rect.width;
		const height = img.naturalHeight || Number(img.getAttribute("height")) || rect.height;
		const lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src") || img.getAttribute("data-original") || "";
		if ((width && width < MIN && height < MIN) || (!width && !lazy)) continue;
		if (/avatar|icon|logo|emoji|sprite|badge/i.test(`${img.className} ${img.alt} ${img.src}`) && width < 400) continue;
		const link = img.closest("a[href]");
		const sources = img.parentElement && img.parentElement.tagName === "PICTURE"
			? [...img.parentElement.querySelectorAll("source[srcset]")].map(source => largest(source.getAttribute("srcset"))) : [];
		const best = (link && picture.test(link.href) && link.href)
			|| largest(img.getAttribute("srcset") || img.getAttribute("data-srcset")) || sources[0] || lazy || img.currentSrc || img.src;
		add(best, img.alt || img.title, width, height);
	}
	// galleries of links to pictures (thumbnails elsewhere)
	for (const link of document.querySelectorAll("a[href]")) {
		if (picture.test(link.href) && link.querySelector("img")) add(link.href, link.textContent, 0, 0);
	}
	const meta = document.querySelector('meta[property="og:image"]');
	if (found.length === 0 && meta && meta.content) add(meta.content, document.title, 0, 0);
	return { title: document.title, url: location.href, pictures: found.slice(0, 300) };
}

COMMANDS.pictures = async message => {
	const tab = message.tabId >= 0 ? await browser.tabs.get(message.tabId) : await activeTab();
	if (!scriptable(tab)) throw new Error("no page");
	const result = await inTab(tab.id, collectPictures);
	if (!result) return { title: tab.title, url: tab.url, pictures: [] };
	for (const item of result.pictures) {
		if (item.src.startsWith("blob:")) item.src = (await blobData(item.src, tab.id, 0)) || "";
	}
	result.pictures = result.pictures.filter(item => item.src);
	return result;
};
