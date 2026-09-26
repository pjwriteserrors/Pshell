function splitAnimationId(value) {
	const raw = String(value || "").trim();
	const parts = raw.split(":");
	if (parts.length !== 2) return { id: "", kind: "", name: "" };
	return { id: raw, kind: parts[0], name: parts[1] };
}

function displayLabel(value) {
	const parts = splitAnimationId(value);
	if (!parts.id) return "";
	if (parts.kind === "shader") return `${parts.name}  shader`;
	if (parts.kind === "nirimation") return `${parts.name}  block`;
	if (parts.kind === "style") return `${parts.name}  style`;
	return parts.name;
}

function parseOptions(raw) {
	const seen = ({});
	const values = String(raw || "")
		.split("\n")
		.map(line => String(line).trim())
		.filter(line => line !== "");

	const result = [];
	for (const line of values) {
		const fields = line.split("\t");
		const value = fields[0];
		if (seen[value]) continue;
		seen[value] = true;
		const parts = splitAnimationId(value);
		if (!parts.id) continue;
		result.push({
			id: parts.id,
			kind: parts.kind,
			name: parts.name,
			label: displayLabel(parts.id),
			preview: fields.length > 1 ? fields.slice(1).join("\t") : ""
		});
	}

	return result;
}

function chooseSelectedId(rawState, options, fallbackShaderName) {
	const wanted = String(rawState || "").trim();
	if (options.some(option => option.id === wanted)) return wanted;

	const fallbackShaderId = fallbackShaderName ? `shader:${fallbackShaderName}` : "";
	if (fallbackShaderId !== "" && options.some(option => option.id === fallbackShaderId))
		return fallbackShaderId;

	return options.length > 0 ? String(options[0].id || "") : "";
}
