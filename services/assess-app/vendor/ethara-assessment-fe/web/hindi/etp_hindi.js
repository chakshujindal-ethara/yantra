// Hindi typing for the Transcription question: the English letters typed (mera) become Devanagari (मेरा).
//
// The spelling rules below are copied from the Strix workbench (custom_addons/strix/static/src/workbench/app.js,
// hindiRules / hindiSuggestions); hindi_typing.js and its three word lists are Strix's own files, copied as they
// are. Nothing here is a model and nothing leaves the browser. The Flutter app loads these files only when an exam
// has a Transcription question, then calls window.EtpHindi.
window.EtpHindi = (function () {
  const HI_CONSONANTS = [
    ["chh", "छ"], ["ksh", "क्ष"], ["shh", "ष"], ["gy", "ज्ञ"], ["kh", "ख"], ["gh", "घ"], ["ch", "च"], ["jh", "झ"],
    ["Th", "ठ"], ["Dh", "ढ"], ["th", "थ"], ["dh", "ध"], ["ph", "फ"], ["bh", "भ"], ["Sh", "ष"], ["sh", "श"],
    ["k", "क"], ["g", "ग"], ["c", "क"], ["j", "ज"], ["T", "ट"], ["D", "ड"], ["N", "ण"], ["R", "ड़"], ["t", "त"],
    ["d", "द"], ["n", "न"], ["p", "प"], ["b", "ब"], ["m", "म"], ["y", "य"], ["r", "र"], ["l", "ल"], ["v", "व"],
    ["w", "व"], ["s", "स"], ["h", "ह"], ["f", "फ़"], ["z", "ज़"], ["q", "क़"], ["x", "क्स"],
  ];
  const HI_VOWELS = [  // [English letters, independent vowel, vowel sign after a consonant]
    ["aa", "आ", "ा"], ["ai", "ऐ", "ै"], ["au", "औ", "ौ"], ["ee", "ई", "ी"], ["ii", "ई", "ी"], ["oo", "ऊ", "ू"],
    ["uu", "ऊ", "ू"], ["ei", "ए", "े"], ["A", "आ", "ा"], ["I", "ई", "ी"], ["U", "ऊ", "ू"], ["a", "अ", ""],
    ["i", "इ", "ि"], ["u", "उ", "ु"], ["e", "ए", "े"], ["o", "ओ", "ो"],
  ];
  const HI_VIRAMA = "्";
  const HI_LONG_SIGN = { "ि": "ी", "ु": "ू" };
  const HI_LONG_VOWEL = { "इ": "ई", "उ": "ऊ" };
  // Words that stay in English letters: Strix's seeded English list and the backchannel spelled in English letters.
  const KEPT = new Set(("air call college control dating flight grad late meeting meetings missus mister pause "
    + "phone play school speaker television timing traffic um").split(" "));

  function hindiRules(word, { medialNasal = true, finalNasal = true, longFinal = true, clusters = true } = {}) {
    const out = [];
    let bare = false;  // the last letter is a consonant still without its vowel
    let i = 0;
    while (i < word.length) {
      const rest = word.slice(i);
      const vowel = HI_VOWELS.find(([latin]) => rest.startsWith(latin));
      const consonant = HI_CONSONANTS.find(([latin]) => rest.startsWith(latin));
      if (vowel && (!consonant || vowel[0].length >= consonant[0].length)) {
        const [latin, independent, sign] = vowel;
        const next = word.slice(i + latin.length);
        const nasalEnd = finalNasal && latin !== "a" && next === "n";  // main -> मैं, nahin -> नहीं
        let letter = bare ? sign : independent;
        if (longFinal && latin.length === 1 && (next === "" || nasalEnd)) {  // mera -> मेरा, abhi -> अभी
          if (latin !== "a") {
            letter = bare ? (HI_LONG_SIGN[sign] || sign) : (HI_LONG_VOWEL[independent] || independent);
          } else if (bare && out.length > 1) {
            letter = "ा";
          }
        }
        out.push(letter);
        bare = false;
        i += latin.length;
        if (nasalEnd) {
          out.push("ं");
          i += 1;
        }
        continue;
      }
      if (consonant) {
        const [latin, letter] = consonant;
        const next = word.slice(i + latin.length);
        if (medialNasal && latin === "n" && !bare && out.length && /^[dgkjbpc]/.test(next)) {  // andar -> अंदर
          out.push("ं");
          i += 1;
          continue;
        }
        if (bare && clusters) out.push(HI_VIRAMA);
        out.push(letter);
        bare = true;
        i += latin.length;
        continue;
      }
      i += 1;  // no rule for this character (an apostrophe)
    }
    return out.join("");
  }

  // Up to five options for one typed word, best first; the English letters as typed are always one of them.
  function suggestions(latin) {
    const word = /^[A-Z][a-z']*$|^[A-Z']+$/.test(latin) ? latin.toLowerCase() : latin;
    const options = [
      hindiRules(word),
      hindiRules(word, { medialNasal: false }),
      hindiRules(word, { clusters: false }),
      hindiRules(word, { longFinal: false, finalNasal: false, medialNasal: false }),
    ];
    const candrabindu = options.filter((o) => o.endsWith("ं")).map((o) => `${o.slice(0, -1)}ँ`);
    const devanagari = [...new Set([...options, ...candrabindu])].filter(Boolean);
    const english = word.toLowerCase();
    const rules = KEPT.has(english) ? [english, ...devanagari].slice(0, 5) : [...devanagari.slice(0, 4), english];
    return window.StrixHindi ? window.StrixHindi.suggest(word, rules, KEPT) : rules;
  }

  // English words that start with the letters typed, most common first (empty when the letters spell Hindi).
  function englishWords(latin) {
    return window.StrixHindi && window.StrixHindi.englishWords ? window.StrixHindi.englishWords(latin) : [];
  }

  return { suggestions, englishWords };
})();
