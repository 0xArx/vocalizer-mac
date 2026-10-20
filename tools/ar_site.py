# Builds website/ar/index.html and website/ar/muslim.html from the English pages: python3 tools/ar_site.py
# Add a translation here for any new English text, then check its output: it prints any English left on the Arabic pages.
import re
import os; W=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'website') + '/'
common={
 "Vocalizer logo: a voice waveform in a glowing ring":"شعار Vocalizer: موجة صوت داخل حلقة مضيئة",
 "Main":"الرئيسية","Footer":"التذييل","Download":"تنزيل","Apple silicon":"معالج Apple",
 "macOS 14.2 or later":"macOS 14.2 أو أحدث","Ready in a minute.":"جاهز خلال دقيقة.",
 "Requires a Mac with Apple silicon (M1 or later) and macOS 14.2 or later.":"يتطلب Mac بمعالج Apple (M1 أو أحدث) ونظام macOS 14.2 أو أحدث.",
 "Open it":"افتحه","Switch it on":"شغّله","Allow":"سماح","Mute swear words":"كتم الألفاظ البذيئة",
 "privacy policy":"سياسة الخصوصية","Download Vocalizer":"تنزيل Vocalizer","110 MB":"110 ميغابايت",
 "© 2026 Vocalizer. Open source under the MIT license.":"© 2026 Vocalizer. مفتوح المصدر بترخيص MIT.",
 "Privacy":"الخصوصية","Terms":"الشروط","Releases":"الإصدارات","Support":"الدعم","Source":"الشيفرة المصدرية","Home":"الرئيسية",
 "Install":"تثبيت","Switch between light and dark":"التبديل بين الوضع الفاتح والداكن","Version 0.3.9":"الإصدار 0.3.9","Fast":"سريع","Clean":"نقي","Best":"الأفضل","Calls":"مكالمات",
}
index={
 "Vocalizer for Mac: remove the music, keep the voices":"Vocalizer لأجهزة Mac: أزل الموسيقى واحتفظ بالأصوات",
 "Vocalizer removes the music from anything your Mac plays and keeps the voices. YouTube, Apple Music, Spotify, podcasts. Runs privately on your Mac, free and open source.":"يزيل Vocalizer الموسيقى من أي شيء يشغّله الـ Mac ويُبقي الأصوات. يوتيوب والبودكاست وغيرها. يعمل بخصوصية على جهازك، مجاني ومفتوح المصدر.",
 "Vocalizer for Mac":"Vocalizer لأجهزة Mac",
 "Remove the music from anything your Mac plays. Keep the voices.":"أزل الموسيقى من أي شيء يشغّله الـ Mac، واحتفظ بالأصوات.",
 "Features":"المزايا","Modes":"الأوضاع","FAQ":"أسئلة",
 "Keep the voices.":"احتفظ بالأصوات.","Lose the music.":"وتخلّص من الموسيقى.",
 "Download for Mac":"تنزيل لأجهزة Mac","View source":"عرض الشيفرة","Free":"مجاني",
 "What you hear.":"ما تسمعه.","Flip the switch.":"جرّب المفتاح.","Vocalizer off":"Vocalizer متوقف",
 "A voice waveform; with Vocalizer on, the music around it falls away":"موجة صوت؛ عند تشغيل Vocalizer تختفي الموسيقى من حولها",
 "Voices":"الأصوات","Music":"الموسيقى",
 "One switch in your menu bar.":"مفتاح واحد في شريط القوائم.",
 "Turn it on and every app plays without its music: YouTube in any browser, Apple Music, Spotify, podcasts, lectures, films. Speech, singing and dialogue come through clearly.":"شغّله وتعمل كل التطبيقات بلا موسيقى: يوتيوب في أي متصفح، والبودكاست، والمحاضرات، والأفلام. يصل الكلام والغناء والحوار بوضوح.",
 "Turn it off and your Mac sounds exactly as before. Press":"أوقفه ويعود صوت الـ Mac كما كان تمامًا. اضغط",
 "to switch it from anywhere.":"لتشغيله أو إيقافه من أي مكان.",
 "The Vocalizer menu: the on/off switch, the four modes, the output and Mute swear words":"قائمة Vocalizer: مفتاح التشغيل، والأوضاع الأربعة، ومخرج الصوت، وكتم الألفاظ البذيئة",
 "Works with every app":"يعمل مع كل التطبيقات",
 "Vocalizer works on your Mac's sound itself, so there's nothing to install in each app or browser.":"يعمل Vocalizer على صوت الـ Mac نفسه، فلا حاجة لتثبيت أي شيء في كل تطبيق أو متصفح.",
 "Lips stay in sync":"تبقى الشفاه متزامنة",
 "Video players hold the picture back by exactly the processing delay, so faces and voices line up.":"تؤخّر مشغّلات الفيديو الصورة بمقدار تأخير المعالجة تمامًا، فتتطابق الوجوه والأصوات.",
 "Private by design":"خاص بطبيعته",
 "Audio is processed on your Mac's Neural Engine and GPU. It is never recorded, stored or sent anywhere.":"يُعالَج الصوت بمحرك Neural Engine ومعالج الرسوميات في جهازك. لا يُسجَّل ولا يُخزَّن ولا يُرسَل إلى أي مكان.",
 "An optional switch silences swear words as they play, recognized on your Mac, with no extra delay. Needs macOS 26 or later.":"مفتاح اختياري يكتم الألفاظ البذيئة أثناء تشغيلها، ويجري التعرّف عليها على جهازك، دون تأخير إضافي. يتطلب macOS 26 أو أحدث.",
 "Speakers and headphones":"السماعات وسماعات الرأس",
 "Plug in headphones or connect AirPods and the sound follows. Your volume keys keep working.":"صِل سماعات الرأس أو AirPods وينتقل الصوت إليها. تبقى أزرار الصوت تعمل.",
 "Signed and notarized":"موقّع ومعتمد من Apple",
 "Signed with an Apple Developer ID and checked by Apple, so it opens without warnings. Free and open source.":"موقّع بمعرّف مطوّر Apple وتفحصه Apple، فيُفتح دون تحذيرات. مجاني ومفتوح المصدر.",
 "Choose speed or quality.":"اختر السرعة أو الجودة.",
 "Cleaner separation needs a little more time. With video sync on, the delay stays out of sight: the video simply starts a moment later.":"الفصل الأنقى يحتاج وقتًا أطول قليلًا. ومع مزامنة الفيديو يبقى التأخير غير ملحوظ: يبدأ الفيديو بعد لحظة فقط.",
 "Lowest delay, for calls and games. Fast sounds cleaner for videos and talks.":"أقل تأخير، للمكالمات والألعاب. «سريع» أنقى للفيديوهات والمحاضرات.",
 "s":"ث","Default":"افتراضي",
 "Everyday videos, music with singing.":"الفيديوهات اليومية، والموسيقى مع الغناء.",
 "Music apps and cleaner voices.":"تطبيقات الموسيقى وأصوات أنقى.",
 "The cleanest voices. One-time 400 MB download.":"أنقى الأصوات. تنزيل لمرة واحدة بحجم 400 ميغابايت.",
 "Delay before you hear the voice, measured on an M-series MacBook with video sync on. Want it simpler? Turn on":"التأخير قبل أن تسمع الصوت، مقيس على MacBook بمعالج M مع تفعيل مزامنة الفيديو. تريد قائمة أبسط؟ فعّل",
 "Fast only":"سريع فقط","in Settings and the menu becomes one switch.":"في الإعدادات وتصبح القائمة مفتاحًا واحدًا.",
 "Download the zip and open it. Drag":"نزّل الملف المضغوط وافتحه. اسحب",
 "to your Applications folder.":"إلى مجلد التطبيقات.",
 "Vocalizer lives in the menu bar as its waveform logo. For video sync, click":"يظهر Vocalizer في شريط القوائم بشعار الموجة. لمزامنة الفيديو انقر",
 "in its menu and enter your password once.":"في قائمته وأدخل كلمة السر مرة واحدة.",
 "Flip the switch, then click":"شغّل المفتاح ثم انقر",
 "when macOS asks about System Audio Recording. Play something.":"عندما يسألك macOS عن «تسجيل صوت النظام». ثم شغّل أي شيء.",
 "Good to know.":"معلومات مفيدة.","Is it free?":"هل هو مجاني؟",
 "Yes. Vocalizer is free and open source under the MIT license, and the source code is public.":"نعم. Vocalizer مجاني ومفتوح المصدر بترخيص MIT، وشيفرته المصدرية متاحة للجميع.",
 "Does it send my audio anywhere?":"هل يرسل صوتي إلى أي مكان؟",
 "No. Separation runs entirely on your Mac. Vocalizer only goes online to check for updates (and download one when you say so), and to download the Best model if you choose it. See the":"لا. يجري الفصل بالكامل على جهازك. لا يتصل Vocalizer بالإنترنت إلا للبحث عن التحديثات (وتنزيلها حين توافق)، ولتنزيل نموذج «الأفضل» إن اخترته. راجع",
 "Why does macOS ask for System Audio Recording?":"لماذا يطلب macOS إذن «تسجيل صوت النظام»؟",
 "Vocalizer needs to hear what your Mac plays in order to remove the music. macOS asks once. Nothing is recorded or saved.":"يحتاج Vocalizer إلى سماع ما يشغّله الـ Mac ليزيل الموسيقى. يسأل macOS مرة واحدة، ولا يُسجَّل أو يُحفَظ أي شيء.",
 "Why is there a delay?":"لماذا يوجد تأخير؟",
 "The model needs a short slice of sound to tell voices from music. With video sync on, video players wait for the voices, so you won't notice it in videos. Games and calls do hear it; use Calls mode for those.":"يحتاج النموذج إلى مقطع قصير من الصوت ليميّز الأصوات من الموسيقى. ومع مزامنة الفيديو تنتظر المشغّلات الأصوات، فلن تلاحظه في الفيديوهات. أما الألعاب والمكالمات فتسمعه؛ استخدم وضع «مكالمات» لها.",
 "Does it remove every instrument perfectly?":"هل يزيل كل الآلات بشكل مثالي؟",
 "It removes most music very well. Heavy reverb, backing vocals and choirs may leave traces. Try Clean or Best for the cleanest result.":"يزيل معظم الموسيقى جيدًا جدًا. قد يبقى أثر خفيف مع الصدى الكثيف والأصوات المساندة والجوقات. جرّب «نقي» أو «الأفضل» لأنقى نتيجة.",
 "Can I install it from the Terminal?":"هل يمكنني تثبيته من الطرفية؟",
 "Yes. Paste this into Terminal: it downloads the latest version, installs the app and the video sync device (macOS asks for your password once), and opens Vocalizer.":"نعم. الصق هذا في الطرفية: ينزّل أحدث إصدار، ويثبّت التطبيق وجهاز مزامنة الفيديو (يطلب macOS كلمة السر مرة واحدة)، ثم يفتح Vocalizer.",
 "Copy the install command":"نسخ أمر التثبيت","Copy":"نسخ",
 "How do I get updates?":"كيف أحصل على التحديثات؟",
 "Vocalizer checks for new versions every few hours. When there's one, a small note appears in its menu; nothing installs until you click":"يبحث Vocalizer عن إصدارات جديدة كل بضع ساعات. وعند وجود إصدار تظهر ملاحظة صغيرة في قائمته؛ ولا يُثبَّت شيء حتى تنقر",
 "Update…":"تحديث",", see what changed, and choose":"، وترى ما الجديد، وتختار",
 ". You can also right-click the menu bar icon and choose":". يمكنك أيضًا النقر بزر الماوس الأيمن على أيقونته واختيار",
 "Check for Updates…":"البحث عن تحديثات…",", or turn on":"، أو تفعيل",
 "Install updates automatically":"تثبيت التحديثات تلقائيًا",
 "in Settings if you'd rather not think about it.":"في الإعدادات إن كنت لا تريد التفكير في الأمر.",
 "Are updates safe?":"هل التحديثات آمنة؟",
 "Each update must carry Vocalizer's private signature and the same Apple Developer ID, so a fake or tampered update from a hacked server is refused, and Apple scans every release. What no updater can prove is that a developer stays trustworthy, which is true of every app that updates itself. Vocalizer only ever has one permission, System Audio Recording, and any new permission would make macOS ask you first. Every change is public on the":"يجب أن يحمل كل تحديث توقيع Vocalizer الخاص ومعرّف مطوّر Apple نفسه، فيُرفض أي تحديث مزيّف أو معدَّل من خادم مخترق، وتفحص Apple كل إصدار. ما لا يستطيع أي نظام تحديث إثباته هو أن المطوّر سيبقى أهلًا للثقة، وهذا ينطبق على كل تطبيق يحدّث نفسه. لا يملك Vocalizer إلا إذنًا واحدًا هو «تسجيل صوت النظام»، وأي إذن جديد سيجعل macOS يسألك أولًا. كل تغيير منشور علنًا في",
 "releases page":"صفحة الإصدارات",", and by default nothing installs without your OK.":"، ولا يُثبَّت شيء دون موافقتك افتراضيًا.",
 "Does it work on Intel Macs?":"هل يعمل على أجهزة Mac بمعالج Intel؟",
 "No. Vocalizer needs Apple silicon (M1 or later), because it runs its models on the Neural Engine and GPU.":"لا. يحتاج Vocalizer إلى معالج Apple (M1 أو أحدث) لأنه يشغّل نماذجه على Neural Engine ومعالج الرسوميات.",
 "How do I uninstall it?":"كيف ألغي تثبيته؟",
 "Right-click Vocalizer in your Applications folder and choose":"انقر بزر الماوس الأيمن على Vocalizer في مجلد التطبيقات واختر",
 "Services › Uninstall Vocalizer":"الخدمات › إلغاء تثبيت Vocalizer",
 ", or just drag it to the Bin and Vocalizer offers to clean up after itself. You can also right-click its icon in the menu bar.":"، أو اسحبه إلى سلة المهملات وسيعرض Vocalizer إزالة بقاياه. يمكنك أيضًا النقر بزر الماوس الأيمن على أيقونته في شريط القوائم.",
 "Hear what matters.":"اسمع ما يهم.","Free for every Mac with Apple silicon.":"مجاني لكل Mac بمعالج Apple.",
 "For Muslims":"للمسلمين",
 "Vocalizer removes the music from anything your Mac plays: videos, podcasts, streams and songs. It all happens on your Mac, as it plays.":"يزيل Vocalizer الموسيقى من أي شيء يشغّله الـ Mac: الفيديوهات والبودكاست والبث والأغاني. يحدث كل ذلك على جهازك، أثناء التشغيل.",
 ", or just drag it to the Bin and Vocalizer offers to clean up after itself. You can also right-click its icon in the menu bar. It removes the app, its audio device, the downloaded models and its settings, and puts your speakers back to normal. From the Terminal you can also run":"، أو اسحبه إلى سلة المهملات وسيعرض Vocalizer إزالة بقاياه. يمكنك أيضًا النقر بزر الماوس الأيمن على أيقونته في شريط القوائم. يزيل التطبيق وجهاز الصوت الخاص به والنماذج التي نُزّلت وإعداداته، ويعيد السماعات إلى وضعها الطبيعي. ومن الطرفية يمكنك أيضًا تشغيل",
}
muslim={
 "Vocalizer for Muslims: remove music from everything on your Mac":"Vocalizer للمسلمين: أزل الموسيقى من كل شيء على جهاز Mac",
 "For Muslims who keep away from music: Vocalizer removes the music from lectures, YouTube, reels, news and ads on your Mac and keeps the voices. Free, private, and fully on your Mac.":"للمسلمين الذين يتجنبون الموسيقى: يزيل Vocalizer الموسيقى من المحاضرات ويوتيوب والمقاطع القصيرة والأخبار والإعلانات على جهاز Mac ويُبقي الأصوات. مجاني وخاص ويعمل بالكامل على جهازك.",
 "Vocalizer: hear the knowledge, not the music":"Vocalizer: استمع إلى العلم، لا إلى الموسيقى",
 "Removes music from everything your Mac plays, keeps the voices. Free, private, fully on your Mac.":"يزيل الموسيقى من كل ما يشغّله الـ Mac ويُبقي الأصوات. مجاني وخاص ويعمل بالكامل على جهازك.",
 "Where it works":"أين يعمل","Questions":"أسئلة",
 "Hear the knowledge.":"استمع إلى العلم.","Not the music.":"لا إلى الموسيقى.",
 "For Muslims who keep away from music. Vocalizer takes the music out of everything your Mac plays, from lectures and reels to news and ads, and keeps the voices. It all happens on your Mac, and nothing ever leaves it.":"للمسلمين الذين يتجنبون الموسيقى. يزيل Vocalizer الموسيقى من كل ما يشغّله الـ Mac، من المحاضرات والمقاطع القصيرة إلى الأخبار والإعلانات، ويُبقي الأصوات. يحدث كل ذلك على جهازك، ولا يغادره شيء أبدًا.",
 "Download free for Mac":"تنزيل مجاني لأجهزة Mac","How your privacy is protected":"كيف تُحمى خصوصيتك",
 "Free, no ads":"مجاني، بلا إعلانات",
 "One switch. Music gone everywhere.":"مفتاح واحد. وتختفي الموسيقى من كل مكان.",
 "You don't have to skip the talk because of its intro music, or mute a video and lose the words. Vocalizer works on your Mac's sound itself, so every app and every website is covered at once.":"لن تحتاج إلى تخطّي المحاضرة بسبب موسيقى مقدمتها، أو كتم الفيديو فتفوتك الكلمات. يعمل Vocalizer على صوت الـ Mac نفسه، فيشمل كل تطبيق وكل موقع في آن واحد.",
 "Lectures and talks":"المحاضرات والدروس",
 "Islamic talks, courses and podcasts that open with music or play it underneath.":"الدروس والدورات الإسلامية والبودكاست التي تبدأ بموسيقى أو تضعها في الخلفية.",
 "YouTube, reels and shorts":"يوتيوب والمقاطع القصيرة",
 "In Safari, Chrome or any browser, including Instagram, TikTok and Facebook on the web.":"في Safari أو Chrome أو أي متصفح، بما فيها إنستغرام وتيك توك وفيسبوك على الويب.",
 "News and documentaries":"الأخبار والأفلام الوثائقية",
 "Background scores and dramatic stings removed, the reporting and narration kept.":"تُزال الموسيقى التصويرية والمؤثرات الدرامية، ويبقى التقرير والسرد.",
 "Ads and trailers":"الإعلانات والعروض الترويجية",
 "The jingles that sneak into everything, gone before they reach your ears.":"المقاطع الموسيقية التي تتسلل إلى كل شيء، تختفي قبل أن تصل إلى أذنيك.",
 "Nasheeds with instruments":"الأناشيد المصحوبة بآلات",
 "Keep the voices, lose the instruments, on the versions that come with them.":"احتفظ بالأصوات وتخلّص من الآلات في النسخ التي تحتوي عليها.",
 "Classes and meetings":"الدروس والاجتماعات",
 "Online classes and recordings, with Calls mode for the lowest delay.":"الدروس عبر الإنترنت والتسجيلات، مع وضع «مكالمات» لأقل تأخير.",
 "Recitation and voices are kept: Vocalizer only takes out what isn't voice. It removes most music very well, but no tool is perfect. Heavy reverb, choirs and backing vocals can leave faint traces, and Best mode removes the most.":"تبقى التلاوة والأصوات: لا يزيل Vocalizer إلا ما ليس صوتًا. يزيل معظم الموسيقى جيدًا جدًا، لكن لا توجد أداة مثالية. قد يبقى أثر خفيف مع الصدى الكثيف والجوقات والأصوات المساندة، ووضع «الأفضل» يزيل أكثر.",
 "Private by design. Not by promise.":"خاص بطبيعته، لا بالوعود.",
 "An app that hears everything your Mac plays has to earn your trust. Vocalizer is built so it doesn't have to ask for it: you can check every part of this yourself.":"تطبيق يسمع كل ما يشغّله جهازك يجب أن يستحق ثقتك. بُني Vocalizer بحيث لا يحتاج إلى طلبها: يمكنك التحقق من كل ذلك بنفسك.",
 "Fully on your Mac":"بالكامل على جهازك",
 "The music is removed by your Mac's own Neural Engine and GPU. No servers, no cloud, works offline.":"تُزال الموسيقى بمحرك Neural Engine ومعالج الرسوميات في جهازك. بلا خوادم ولا سحابة، ويعمل دون إنترنت.",
 "Nothing recorded, nothing sent":"لا تسجيل ولا إرسال",
 "Sound is processed in memory and played straight back. It is never saved to disk and never uploaded.":"يُعالَج الصوت في الذاكرة ويُعاد تشغيله فورًا. لا يُحفَظ على القرص ولا يُرفَع أبدًا.",
 "No account, no tracking":"بلا حساب ولا تتبّع",
 "No sign-up, no ads, no analytics, no cookies. Vocalizer doesn't know who you are and doesn't want to.":"بلا تسجيل ولا إعلانات ولا إحصاءات ولا ملفات تعريف ارتباط. لا يعرف Vocalizer من أنت، ولا يريد أن يعرف.",
 "Open source":"مفتوح المصدر",
 "All of the code is public, so anyone can check exactly what it does. Only the maintainer can publish releases.":"الشيفرة كلها منشورة، فيمكن لأي أحد التحقق مما يفعله بالضبط. ولا ينشر الإصدارات إلا المطوّر المسؤول.",
 "Signed and checked by Apple":"موقّع ومفحوص من Apple",
 "Every release is signed with an Apple Developer ID and notarized by Apple, so macOS opens it without warnings.":"كل إصدار موقّع بمعرّف مطوّر Apple ومعتمد من Apple، فيفتحه macOS دون تحذيرات.",
 "Updates ask first":"التحديثات تستأذن أولًا",
 "New versions only install when you say so, and only after their signature is verified. Its one connection is checking for updates.":"لا تُثبَّت الإصدارات الجديدة إلا بموافقتك، وبعد التحقق من توقيعها. واتصاله الوحيد بالإنترنت هو البحث عن التحديثات.",
 "Mute swear words, too.":"وكتم الألفاظ البذيئة أيضًا.","Turn on":"فعّل",
 "and Vocalizer silences them as they play, recognized by your Mac's own speech recognition, with no extra delay. Good for family viewing, and for keeping your ears clean.":"فيكتمها Vocalizer أثناء تشغيلها، بالتعرّف على الكلام على جهازك نفسه، دون تأخير إضافي. مناسب للمشاهدة العائلية، ولصون سمعك.",
 "Works best in Best and Clean modes, and needs macOS 26 or later. Like any speech recognition, it can occasionally miss a word.":"يعمل أفضل في وضعي «الأفضل» و«نقي»، ويتطلب macOS 26 أو أحدث. وككل تعرّف على الكلام، قد تفوته كلمة أحيانًا.",
 "The Vocalizer menu with the Mute swear words switch":"قائمة Vocalizer مع مفتاح كتم الألفاظ البذيئة",
 "Download Vocalizer and drag it to your Applications folder. It's free, with nothing to buy inside.":"نزّل Vocalizer واسحبه إلى مجلد التطبيقات. مجاني، ولا شيء للشراء بداخله.",
 "It lives in the menu bar. For video, click":"يظهر في شريط القوائم. للفيديو انقر",
 "in its menu once, so lips stay in sync with the voice.":"في قائمته مرة واحدة، لتبقى الشفاه متزامنة مع الصوت.",
 "Flip the switch and click":"شغّل المفتاح وانقر",
 "when macOS asks about System Audio Recording. That's it.":"عندما يسألك macOS عن «تسجيل صوت النظام». هذا كل شيء.",
 "Questions.":"أسئلة.","Is it really free?":"هل هو مجاني فعلًا؟",
 "Yes. No price, no ads, no subscription and nothing to buy inside. It's open source under the MIT license.":"نعم. بلا سعر ولا إعلانات ولا اشتراك ولا شيء للشراء بداخله. وهو مفتوح المصدر بترخيص MIT.",
 "Does it change Qur'an recitation?":"هل يغيّر تلاوة القرآن؟",
 "No. Recitation is voice, and Vocalizer keeps voices. It only removes what isn't voice, so recitation and adhan come through as they are.":"لا. التلاوة صوت، وVocalizer يُبقي الأصوات. لا يزيل إلا ما ليس صوتًا، فتصل التلاوة والأذان كما هي.",
 "Will it catch every bit of music?":"هل يزيل كل أثر للموسيقى؟",
 "Most music is removed very well, especially in Clean and Best modes. Heavy reverb, choirs and backing vocals can leave faint traces. If something matters a lot to you, use Best mode.":"يُزيل معظم الموسيقى جيدًا جدًا، خاصة في وضعي «نقي» و«الأفضل». قد يبقى أثر خفيف مع الصدى الكثيف والجوقات والأصوات المساندة. إن كان الأمر مهمًا لك فاستخدم وضع «الأفضل».",
 "Does it work on YouTube, Instagram and TikTok?":"هل يعمل مع يوتيوب وإنستغرام وتيك توك؟",
 "Yes, in any browser and in any Mac app, because it works on your Mac's sound itself rather than inside one app.":"نعم، في أي متصفح وأي تطبيق على الـ Mac، لأنه يعمل على صوت الجهاز نفسه لا داخل تطبيق واحد.",
 "Can anyone see what I watch or listen to?":"هل يمكن لأحد أن يرى ما أشاهده أو أسمعه؟",
 "No. Vocalizer has no account and sends nothing anywhere. The sound is processed on your Mac and never saved. Its only connection is checking for updates. See the":"لا. لا يوجد حساب في Vocalizer ولا يرسل شيئًا إلى أي مكان. يُعالَج الصوت على جهازك ولا يُحفَظ أبدًا. واتصاله الوحيد هو البحث عن التحديثات. راجع",
 "Is there a delay?":"هل يوجد تأخير؟",
 "A short one (about 0.4 s in the default Fast mode). With video sync, video players wait for the voice, so in videos you won't notice it. Use Calls mode for calls and games.":"تأخير قصير (نحو 0.4 ثانية في وضع «سريع» الافتراضي). ومع مزامنة الفيديو تنتظر المشغّلات الصوت، فلن تلاحظه في الفيديوهات. استخدم وضع «مكالمات» للمكالمات والألعاب.",
 "Does it work on iPhone or Windows?":"هل يعمل على iPhone أو Windows؟",
 "Not yet. Vocalizer is for Macs with Apple silicon.":"ليس بعد. Vocalizer لأجهزة Mac بمعالج Apple.",
 "Listen with a clear heart.":"استمع بقلب مطمئن.",
 "Free for every Mac with Apple silicon. Share it with someone who'd benefit.":"مجاني لكل Mac بمعالج Apple. شاركه مع من قد ينتفع به.",
}
def translate(html, table):
    for en, ar in sorted({**common, **table}.items(), key=lambda kv: -len(kv[0])):
        e=re.escape(en)
        html=re.sub(r'>(\s*)'+e+r'(\s*)<', lambda m: '>'+m.group(1)+ar+m.group(2)+'<', html)
        html=re.sub(r'(\s(?:alt|aria-label|content|title)=")'+e+'"', lambda m: m.group(1)+ar+'"', html)
    return html
def finish(html, path_en, path_ar):
    html=re.sub(r'\n  <link rel="alternate" hreflang="(?:en|ar)"[^>]*>', '', html)
    html=html.replace('<html lang="en">','<html lang="ar" dir="rtl">',1)
    html=html.replace(f'<link rel="canonical" href="https://getvocalizer.com{path_en}">',
        f'<link rel="canonical" href="https://getvocalizer.com{path_ar}">\n  <link rel="alternate" hreflang="en" href="https://getvocalizer.com{path_en}">\n  <link rel="alternate" hreflang="ar" href="https://getvocalizer.com{path_ar}">',1)
    html=re.sub(r'<a class="lang" href="[^"]*" lang="ar">العربية</a>', '<a class="lang" href="'+path_en+'" lang="en">English</a>', html)
    html=html.replace('<span data-version>','<span data-version data-prefix="الإصدار ">')
    html=html.replace('<span data-size>','<span data-size data-unit=" ميغابايت">')
    html=html.replace('id="demo-label">','id="demo-label" data-on="Vocalizer يعمل" data-off="Vocalizer متوقف">')
    html=html.replace('id="copy" type="button"','id="copy" type="button" data-done="نُسخ" data-fail="حدّده وانسخه"')
    html=html.replace('href="/muslim"','href="/ar/muslim"').replace('href="/" ','href="/ar" ')
    html=html.replace('<a class="brand" href="/">','<a class="brand" href="/ar">')
    html=html.replace('<footer>\n  <div class="wrap">','<footer>\n  <div class="wrap">',1)
    return html
idx=open(W+'index.html').read()
a=finish(translate(idx,index),'/','/ar')
open(W+'ar/index.html','w').write(a)
m=open(W+'muslim.html').read()
m=m.replace('      <p class="salam" lang="ar" dir="rtl">استمع إلى العلم، بلا موسيقى</p>\n','')
b=finish(translate(m,muslim),'/muslim','/ar/muslim')
b=b.replace('<a href="/">الرئيسية</a>','<a href="/ar">الرئيسية</a>')
open(W+'ar/muslim.html','w').write(b)
# leftover English check
from html.parser import HTMLParser
for name,h in [('ar/index',a),('ar/muslim',b)]:
    class P(HTMLParser):
        def __init__(s): super().__init__(); s.left=[]; s.skip=0
        def handle_starttag(s,t,at):
            if t in('script','style','svg','code','kbd'): s.skip+=1
        def handle_endtag(s,t):
            if t in('script','style','svg','code','kbd'): s.skip-=1
        def handle_data(s,d):
            d=d.strip()
            if d and not s.skip and re.search(r'[A-Za-z]{3,}',d) and not re.fullmatch(r'(Vocalizer|English|Vocalizer %@|MacBook.*)',d): s.left.append(d)
    p=P(); p.feed(h); print(name,'leftover:',[x for x in p.left if not re.search('[؀-ۿ]',x)][:20])
