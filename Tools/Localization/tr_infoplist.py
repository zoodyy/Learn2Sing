# Batch 13: the Info.plist strings, which the system shows rather than the app:
# the microphone permission prompt. They go to InfoPlist.xcstrings, keyed by
# their Info.plist key, and the English is the INFOPLIST_KEY_<key> build setting
# in project.pbxproj (generate.py checks the two still agree).
#
# The prompt follows the device's language, not the one picked in Settings ›
# Language: the system draws it from the app's .lproj folders before the app
# has a say.
from trbase import P

P("NSMicrophoneUsageDescription",
  "Learn2Sing uses the microphone to show how high you are currently singing.",
  "Learn2Sing nutzt das Mikrofon, um dir zu zeigen, wie hoch du gerade singst.",
  "Learn2Sing usa el micrófono para mostrarte en tiempo real lo agudo o grave que cantas.",
  "Learn2Sing utilise le micro pour vous montrer en temps réel la hauteur de la note que vous chantez.",
  "Learn2Sing usa il microfono per mostrarti in tempo reale l’altezza delle note che canti.",
  "O Learn2Sing usa o microfone para mostrar em tempo real o quão agudo ou grave você está cantando.",
  "Learn2Sing gebruikt de microfoon om je live te laten zien hoe hoog je zingt.",
  "Learn2Sing использует микрофон, чтобы показывать, насколько высоко вы сейчас поёте.",
  "Learn2Sing korzysta z mikrofonu, żeby na bieżąco pokazywać, jak wysoko śpiewasz.",
  "Learn2Sing, o anda ne kadar ince ya da kalın söylediğinizi göstermek için mikrofonu kullanır.",
  "Learn2Sing använder mikrofonen för att visa vilken tonhöjd du sjunger på just nu.",
  "Learn2Singはマイクを使って、いま歌っている音の高さを表示します。",
  "Learn2Sing은 마이크를 사용해 지금 부르고 있는 음의 높이를 보여줍니다.",
  "Learn2Sing 使用麦克风实时显示你正在唱的音高。",
  "يستخدم Learn2Sing الميكروفون ليعرض لك مدى ارتفاع النغمة التي تغنيها الآن.")
