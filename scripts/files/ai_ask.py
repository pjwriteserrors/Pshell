"""ai_ask.py JSON – one answer of the local model (Ollama, the model the
files' AI uses) to {"prompt", "text", "system", "json"}; prints
{"text": …} or {"error": …}. For short asks of the shell's windows: the PDF
viewer's translations, explanations and file names."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai  # noqa: E402


def main():
    try:
        ask = json.loads(sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read())
        model = ai.status("").get("text", "")
        if not model:
            raise ai.AiError("No model in Ollama to answer with")
        prompt = str(ask.get("prompt", ""))
        text = str(ask.get("text", ""))[:12000]
        whole = f"{prompt}\n\n{text}" if text else prompt
        answer = ai.generate(model, whole, as_json=bool(ask.get("json")), system=str(ask.get("system", "")), timeout=180)
        print(json.dumps({"text": answer} if not isinstance(answer, dict) else {"json": answer}, ensure_ascii=False))
    except Exception as error:  # noqa: BLE001 – the window shows what went wrong
        print(json.dumps({"error": str(error) or "The model did not answer"}))


if __name__ == "__main__":
    main()
