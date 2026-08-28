#!/usr/bin/env python3
"""Score text as Spanish or English by function-word frequency.

The old shell heuristic only looked for accents or a hand-picked word list, so a
plain sentence like "Primera frase de prueba, para que haya varios trozos" was
sent to TTS as English. Function words are the reliable signal: they are the
most frequent tokens in any real sentence and they barely overlap between the
two languages.
"""
import re, sys, unicodedata

ES = {
    "el","la","los","las","un","una","unos","unas","de","del","al","y","o","pero","que",
    "como","para","por","con","sin","sobre","entre","hasta","desde","cuando","donde",
    "es","son","era","fue","ser","estar","esta","este","esto","esa","ese","eso","hay",
    "no","si","se","su","sus","me","te","le","lo","nos","les","mi","tu","yo","vos","usted",
    "muy","mas","menos","ya","tambien","siempre","nunca","todo","toda","todos","todas",
    "algo","nada","porque","entonces","ahora","aqui","alli","bien","mal","cada","otro",
    "otra","mismo","hacer","tiene","tienen","puede","pueden","vamos","voy","va","dice",
    "primera","primero","segunda","segundo","frase","prueba","gracias","hola","claro",
}
EN = {
    "the","a","an","of","and","or","but","that","which","as","for","by","with","without",
    "about","between","until","from","when","where","is","are","was","were","be","being",
    "been","this","that","these","those","there","not","if","it","its","he","she","they",
    "we","you","i","my","your","his","her","their","our","very","more","less","already",
    "also","always","never","all","every","something","nothing","because","then","now",
    "here","well","each","other","same","make","makes","has","have","had","can","could",
    "will","would","should","do","does","did","to","in","on","at","so","just","only",
}


def detect(text: str) -> str:
    lowered = text.lower()
    if re.search(r"[áéíóúñü¿¡]", lowered):
        return "es"
    stripped = "".join(
        c for c in unicodedata.normalize("NFD", lowered) if unicodedata.category(c) != "Mn"
    )
    words = re.findall(r"[a-z]+", stripped)
    if not words:
        return "en"
    es = sum(1 for w in words if w in ES)
    en = sum(1 for w in words if w in EN)
    if es > en:
        return "es"
    if en > es:
        return "en"
    # Tie: Spanish morphology is distinctive enough to break it.
    if re.search(r"\b\w+(cion|ciones|dad|mente|ando|iendo|amos|aron)\b", stripped):
        return "es"
    return "en"


if __name__ == "__main__":
    src = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else sys.stdin.read()
    print(detect(src))
