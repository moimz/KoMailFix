# KoMailFix

macOS Mail에서 한글 첨부파일 이름이 `????`로 깨지는 문제를 고칩니다.

- **Mail 확장 (KoMailFixExtension)**: 메일을 열 때 원문을 받아 깨진 첨부파일 이름만 고쳐 돌려줍니다. MailKit 보안 핸들러(`MEMessageSecurityHandler`)를 사용하며, 서명·암호화는 하지 않습니다.
- **앱 (KoMailFix)**: 이미 저장된 메일(`~/Library/Mail/V*/…/*.emlx`)을 검사해 백업한 뒤 고치고, Mail이 풀어 저장해 둔 첨부파일의 이름도 바꿉니다. 백업에서 되돌릴 수 있습니다.

## 고치는 유형

| 유형 | 예 |
|---|---|
| RFC 2047 조각이 글자 중간에서 잘림 | `=?UTF-8?B?…?= =?UTF-8?B?…?=`, `=?ks_c_5601-1987?B?…?=` |
| RFC 2231 연속 파라미터가 글자 중간에서 잘림 | `filename*0*=UTF-8''%EC%82; filename*1*=%AC…` |
| 인코딩 없는 EUC-KR/CP949 바이트 | `filename="<CP949 바이트>"` |

고친 이름은 `filename*=UTF-8''…` (RFC 2231) 하나로 다시 씁니다. 서명·암호화된 메일은 건드리지 않습니다.

## 보내는 메일: 첨부파일 이름 NFC

Mail은 첨부파일 이름을 디스크의 형태와 상관없이 NFD(자모 분리, `%E1%84%92%E1%85%A1…`)로 보냅니다. Windows에서는 `ㅎㅏㄴㄱㅡㄹ.pdf`처럼 보이거나 검색이 안 될 수 있습니다. 확장이 보내는 원문의 `filename*`과 `name`만 NFC로 바꿔 보냅니다 (`name`은 RFC 2047 형태 유지). 제목·본문·주소는 원래 NFC라 건드리지 않습니다.

Mail은 확장이 서명할 수 있다고 알려야만(`canSign: true`) 보낼 때 `encode`를 부릅니다. 그래서 작성 창에 서명 옵션이 생기고 기본으로 켜지며, **이 옵션이 켜져 있을 때만** 동작합니다. 실제 서명은 하지 않습니다(`isSigned: false`).

## 설치

[Releases](https://github.com/moimz/KoMailFix/releases/latest)에서 dmg를 받아 KoMailFix를 응용 프로그램 폴더로 끌어 놓고 한 번 실행합니다. 그다음 Mail → 설정 → 확장 프로그램에서 **KoMailFix**를 켭니다. 기존 메일 복구를 쓰려면 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 KoMailFix를 켭니다.

Apple Silicon 맥 전용(arm64), macOS 13 이상입니다.

## 자동 업데이트

앱을 열 때 [Sparkle](https://sparkle-project.org)로 새 버전을 확인하고, 있으면 설치할지 묻습니다 (메뉴 KoMailFix → 업데이트 확인…). 확장은 Mail 안에서 돌기 때문에 업데이트한 뒤에는 Mail을 종료했다가 다시 열어야 새 확장이 적용됩니다.

## 빌드

Developer ID로 서명하고 공증한 Release 빌드를 배포합니다. 개발용으로 컴파일만 확인할 때는:

```bash
xcodebuild -project KoMailFix.xcodeproj -scheme KoMailFix -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 아이콘

`Tools/make-icon.swift`가 파란 둥근 사각형에 편지봉투와 노란 "가" 배지를 그립니다. 앱과 확장(.appex) 두 곳에 같은 아이콘을 넣습니다. 다만 Mail 설정의 확장 목록에는 번들에 아이콘이 있어도 기본 퍼즐 아이콘이 표시됩니다 (macOS 27, Mail 16.0에서 확인).

```bash
xcrun swift Tools/make-icon.swift KoMailFix/Assets.xcassets/AppIcon.appiconset
xcrun swift Tools/make-icon.swift KoMailFixExtension/Assets.xcassets/AppIcon.appiconset
```

## 보정 로직 점검

```bash
xcrun swiftc -O Shared/*.swift Tools/kmfcheck/main.swift -o build/kmfcheck && ./build/kmfcheck test
```

`./build/kmfcheck scan <폴더>`는 .emlx/.eml을 읽기만 하고 고칠 대상을 출력합니다. `./build/kmfcheck show <파일>`은 한 파일의 보정 결과를 보여줍니다.
