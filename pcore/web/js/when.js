// A line of text as an event, the rules of the shell's NasCalendar.parseText
// (the same function): "morgen 15 Uhr Zahnarzt @Praxis", "Fr 18:30-20 Kino",
// "24.12. ganztägig Weihnachten", "jeden Montag 9 Standup 15min".
export function parseText(input, now) {
	let t = ` ${String(input).replace(/\s+/g, " ").trim()} `;
	// a match is cut out of the text; fn returning false puts it back
	const take = (re, fn) => {
		const m = t.match(re);
		if (!m) return false;
		const before = t;
		t = t.slice(0, m.index) + " " + t.slice(m.index + m[0].length);
		if (fn && fn(m) === false) {
			t = before;
			return false;
		}
		return true;
	};
	const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
	let day = null;
	let hour = -1;
	let minute = 0;
	let endHour = -1;
	let endMinute = 0;
	let length = 60;
	let allDay = false;
	let location = "";
	let repeat = "";
	let exact = null;
	const days = ["so|sonntag|sun|sunday", "mo|montag|mon|monday", "di|dienstag|tue|tuesday", "mi|mittwoch|wed|wednesday", "do|donnerstag|thu|thursday", "fr|freitag|fri|friday", "sa|samstag|sat|saturday"];
	const weekday = word => days.findIndex(d => d.split("|").includes(word.toLowerCase().replace(/\.$/, "")));
	const nextDay = (wd, strict) => {
		const add = (wd - today.getDay() + 7) % 7;
		return new Date(today.getFullYear(), today.getMonth(), today.getDate() + (add === 0 && strict ? 7 : add));
	};
	// QML's engine loses array destructuring into these variables: plain fields
	const clock = (h, m, half) => {
		h = Number(h);
		m = Number(m || 0);
		if (half && /pm/i.test(half) && h < 12) h += 12;
		if (half && /am/i.test(half) && h === 12) h = 0;
		return { h: h, m: m };
	};

	take(/\s@\s*(.+?)\s*$/, m => location = m[1]);
	take(/\s(ganzt(?:ä|ae)gig|ganztags|all[- ]day)(?=\s)/i, () => allDay = true);
	take(/\s(?:jede[nrs]?|every)\s+(?:tag|day)(?=\s)/i, () => repeat = "daily");
	take(/\s(t(?:ä|ae)glich|daily)(?=\s)/i, () => repeat = "daily");
	take(/\s(w(?:ö|oe)chentlich|weekly)(?=\s)/i, () => repeat = "weekly");
	take(/\s(?:jede[nrs]?|every)\s+(?:monat|month)(?=\s)|\s(monatlich|monthly)(?=\s)/i, () => repeat = "monthly");
	take(/\s(?:jede[nrs]?|every)\s+(?:jahr|year)(?=\s)|\s(j(?:ä|ae)hrlich|yearly)(?=\s)/i, () => repeat = "yearly");
	take(/\s(?:jede[nrs]?|every)\s+([a-zä]+)(?=\s)/i, m => {
		const wd = weekday(m[1]);
		if (wd >= 0) {
			repeat = "weekly";
			day = nextDay(wd, false);
		} else return false;
	});
	take(/\sin\s+(\d+)\s*(min(?:uten)?|minutes?|std\.?|stunden?|h|hours?)(?=\s)/i, m => {
		const n = Number(m[1]) * (/^m/i.test(m[2]) ? 60000 : 3600000);
		exact = new Date(now.getTime() + n);
	});
	take(/\sin\s+(\d+)\s*(tag(?:en)?|days?|wochen?|weeks?)(?=\s)/i, m => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + Number(m[1]) * (/^w/i.test(m[2]) ? 7 : 1)));
	take(/\s(?:am\s+|on\s+)?(\d{4})-(\d{2})-(\d{2})(?=\s)/, m => day = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
	take(/\s(?:am\s+|on\s+)?(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4})?)?(?=\s)/, m => {
		// "10.30" is no date
		if (Number(m[2]) > 12 || Number(m[2]) < 1 || Number(m[1]) > 31 || Number(m[1]) < 1) return false;
		let year = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : today.getFullYear();
		let d = new Date(year, Number(m[2]) - 1, Number(m[1]));
		if (!m[3] && d < today) d = new Date(year + 1, Number(m[2]) - 1, Number(m[1]));
		day = d;
	});
	take(/\s((?:ü|ue)bermorgen|day after tomorrow)(?=\s)/i, () => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 2));
	take(/\s(morgen|tomorrow)(?=\s)/i, () => day = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1));
	take(/\s(heute|today|tonight|heute abend)(?=\s)/i, () => day = today);
	if (!day) take(/\s(?:(n(?:ä|ae)chste[nrs]?|next)\s+|am\s+|on\s+)?(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)\.?(?=\s)/i, m => day = nextDay(weekday(m[2]), !!m[1]));
	if (!day) take(/^\s(?:am\s+)?(mo|di|mi|do|fr|sa|so)\.?(?=\s)/i, m => day = nextDay(weekday(m[1]), false));
	take(/\s(?:um\s+|at\s+|von\s+|from\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?\s*(?:-|–|bis|to|until)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)?(?=\s)/i, m => {
		if (Number(m[1]) > 23 || Number(m[4]) > 24) return false;
		const from = clock(m[1], m[2], m[3] || m[6]);
		const to = clock(m[4], m[5], m[6]);
		hour = from.h;
		minute = from.m;
		endHour = to.h;
		endMinute = to.m;
	});
	if (hour < 0) take(/\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})(?:[:.](\d{2}))?\s*(uhr|h|am|pm)(?=\s)|\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})[:](\d{2})(?=\s)|\s(?:um|at|ab)\s+(\d{1,2})(?=\s)/i, m => {
		const at = m[1] !== undefined ? clock(m[1], m[2], m[3]) : (m[4] !== undefined ? clock(m[4], m[5]) : clock(m[6], 0));
		hour = at.h;
		minute = at.m;
	});
	// "10.30" is a time only once the day is known (else it could be a date)
	if (hour < 0 && day) take(/\s(?:um\s+|at\s+|ab\s+)?(\d{1,2})\.(\d{2})(?=\s)/, m => {
		if (Number(m[1]) <= 23 && Number(m[2]) <= 59) {
			hour = Number(m[1]);
			minute = Number(m[2]);
		} else return false;
	});
	take(/\s(?:f(?:ü|ue)r\s+|for\s+)?(\d+(?:[.,]\d+)?)\s*(min(?:uten)?\.?|minutes?|std\.?|stunden?|h|hours?)(?=\s)/i, m => {
		length = Number(m[1].replace(",", ".")) * (/^m/i.test(m[2]) ? 1 : 60);
	});
	if (hour < 0 && day) take(/^\s+(\d{1,2})(?=\s)/, m => {
		if (Number(m[1]) <= 23) hour = Number(m[1]);
		else return false;
	});
	const title = t.replace(/\s(am|um|at|on|von|from|ab|bis)(?=\s)/gi, " ").replace(/\s+/g, " ").trim().replace(/^[-–:,]\s*/, "");
	let start;
	let end;
	const when = !!(day || exact || hour >= 0);
	if (exact) {
		start = exact;
		end = new Date(start.getTime() + length * 60000);
	} else if (hour >= 0 && hour <= 23 && !allDay) {
		let base = day ?? today;
		start = new Date(base.getFullYear(), base.getMonth(), base.getDate(), hour, Math.min(59, minute));
		if (!day && start < now) start = new Date(start.getTime() + 86400000);
		end = endHour >= 0 ? new Date(start.getFullYear(), start.getMonth(), start.getDate(), endHour, endMinute) : new Date(start.getTime() + length * 60000);
		if (end <= start) end = new Date(end.getTime() + 86400000);
	} else {
		allDay = true;
		start = day ?? today;
		end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1);
	}
	return { title: title, start: start, end: end, allDay: allDay && !exact, location: location, repeat: repeat, when: when };
}
