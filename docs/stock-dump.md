# 순정 원본 수집 (새 포트용, 읽기 전용)

설치 전 점검에서 `unregistered_build=yes`(미등록 차종·빌드)가 나온 차량의 순정 파일을 USB로 복사합니다. 새 포트의 레시피는 해시만으로 만들 수 없고 실제 원본 바이트가 필요합니다.

## 하는 일과 하지 않는 일

- `/system`을 읽기만 합니다. 다시 마운트하거나 `/system`·`/data`에 쓰지 않으며, 설정과 속성도 바꾸지 않습니다.
- USB의 `GEN5W-STOCK/`에만 씁니다. 파일마다 차량에서 MD5를 다시 계산해, 복사본이 원본과 같을 때만 남깁니다.
- 복사 대상: 패치·참조 대상(`Iap2ServerApp`, `HKMC_DiPO`, `HKMC_GPM`, `PhoneProjection`, `HKMC_TAppService`, `HKMC_TAppVRM`, `SystemUI`의 ODEX/APK), `libCarPlay*.so`, `libopus.so`, `wifi/bcmdhd.ko`, `framework/`의 모든 ODEX/JAR(ODEX 의존성 확인용), 차종 `featurexml.cfg`.
- `MANIFEST.txt`에는 빌드 정보, 파일별 MD5, 설치기 백업 폴더 유무, 설치된 NEMESIS 패키지 이름만 적습니다. VIN·전화번호·Wi-Fi 정보·키는 수집하지 않습니다.

## 사용법

1. 빈 FAT32 USB의 최상위에 `dist/usb-stock-dump/`의 `NEMESIS.data`와 `NEMESIS.sh`를 복사합니다(framework 전체가 들어가므로 여유 공간을 넉넉히 두세요. 실제 크기는 아직 실차에서 재지 않았습니다).
2. 시동을 켜고 부팅이 끝난 뒤 USB를 꽂아 NEMESIS에서 실행합니다. "원본 수집 완료" 알림이 뜰 때까지 USB를 빼지 않습니다.
3. PC에서 검증합니다. 수집 폴더 안에서 실행하지 말고 경로를 인자로 넘기세요.

```sh
python3 -I tools/stock-dump/verify.py /Volumes/USB/GEN5W-STOCK \
    --check /path/to/GEN5W-REPORT/CHECK.txt --sums ~/gen5w-private/SHA256SUMS
```

`--check`는 수집한 파일이 설치 전 점검 때 해시한 파일과 같은지 확인합니다. 출력되는 표(해시와 빌드 정보)는 지원 요청에 붙여도 됩니다.

## 주의

- **수집한 파일은 제조사 파일입니다. GitHub 이슈나 공개 장소에 올리지 마세요.** 개인 환경에서만 분석합니다([포트 절차](porting.md#포트-절차) 2단계).
- 이 도구는 차량에 있는 파일을 그대로 복사합니다. 순정이라는 보증은 아닙니다. `gen5w_backup=present`이거나 다른 수정 패키지가 있으면 순정이 아닐 수 있습니다. 가능하면 같은 차종·빌드의 다른 차량 점검 해시나 공식 업데이트 이미지와 대조하세요.
- 실차에서 실행해 확인한 적은 아직 없습니다(mock 시험만 통과).
