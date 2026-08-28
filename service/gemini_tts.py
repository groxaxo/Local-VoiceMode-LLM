#!/usr/bin/env python3
"""Call Gemini 3.1 Flash TTS and write its 24 kHz PCM response as WAV."""
import argparse, base64, json, os, socket, sys, time, urllib.error, urllib.request, wave
VOICES={"Zephyr","Puck","Charon","Kore","Fenrir","Leda","Orus","Aoede","Callirrhoe","Autonoe","Enceladus","Iapetus","Umbriel","Algieba","Despina","Erinome","Algenib","Rasalgethi","Laomedeia","Achernar","Alnilam","Schedar","Gacrux","Pulcherrima","Achird","Zubenelgenubi","Vindemiatrix","Sadachbia","Sadaltager","Sulafat"}
def extract_audio(data):
    audio=data.get("output_audio") or data.get("outputAudio")
    if isinstance(audio,dict) and audio.get("data"): return base64.b64decode(audio["data"])
    for step in data.get("steps", []):
        for content in step.get("content", []):
            if content.get("type") == "audio" and content.get("data"):
                return base64.b64decode(content["data"])
    raise ValueError("Gemini response contained no output audio")
def write_wav(path,pcm):
    with wave.open(path,"wb") as handle:
        handle.setnchannels(1); handle.setsampwidth(2); handle.setframerate(24000); handle.writeframes(pcm)
def main():
    parser=argparse.ArgumentParser(); parser.add_argument("text"); parser.add_argument("output"); parser.add_argument("--response-file"); args=parser.parse_args()
    voice=os.environ.get("GEMINI_TTS_VOICE","Charon")
    if voice not in VOICES: print("gemini_tts.py: unknown voice %s"%voice,file=sys.stderr); return 2
    try:
        if args.response_file:
            with open(args.response_file,encoding="utf-8") as handle: data=json.load(handle)
        else:
            key=os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY","")
            if not key: raise RuntimeError("GEMINI_API_KEY or GOOGLE_API_KEY not set")
            style=os.environ.get("GEMINI_TTS_STYLE","").strip()
            prompt="Synthesize the following text as speech. Interpret bracketed audio tags as performance direction and do not read them aloud."
            if style: prompt+="\n\nDIRECTOR'S NOTES:\n"+style
            prompt+="\n\nTRANSCRIPT:\n"+args.text
            payload=json.dumps({"model":os.environ.get("GEMINI_TTS_MODEL","gemini-3.1-flash-tts-preview"),"input":prompt,"response_format":{"type":"audio"},"generation_config":{"speech_config":[{"voice":voice}]}}).encode()
            request=urllib.request.Request(os.environ.get("GEMINI_TTS_URL","https://generativelanguage.googleapis.com/v1beta/interactions"),data=payload,headers={"x-goog-api-key":key,"Content-Type":"application/json"},method="POST")
            last_error=None
            for attempt in range(2):
                try:
                    with urllib.request.urlopen(request,timeout=float(os.environ.get("GEMINI_TTS_TIMEOUT_S","120"))) as response: data=json.loads(response.read().decode())
                    break
                except (urllib.error.URLError,json.JSONDecodeError,socket.timeout) as error:
                    last_error=error
                    if attempt==0: time.sleep(.25)
            else: raise last_error
        write_wav(args.output,extract_audio(data)); print(args.output); return 0
    except (KeyError,ValueError,RuntimeError,urllib.error.URLError,json.JSONDecodeError,TimeoutError,socket.timeout) as error:
        print("gemini_tts.py: %s"%error,file=sys.stderr); return 1
if __name__ == "__main__": raise SystemExit(main())
