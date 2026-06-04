# SDXL в ComfyUI — RealVisXL V5.0

Готовый launcher для **[ComfyUI](https://github.com/comfyanonymous/ComfyUI)** с предустановленной фотореалистичной моделью **[RealVisXL V5.0](https://huggingface.co/SG161222/RealVisXL_V5.0)** (SDXL) и стартовым workflow для портретной генерации. Поднимает ComfyUI на `0.0.0.0:8188` на свежем NVIDIA-контейнере одной командой — без ручной охоты за весами и возни с custom nodes.

Подходит для генерации фотореалистичных портретов и сцен по текстовому промпту на собственной (или арендованной) видеокарте, в том числе для тех, кто впервые знакомится с ComfyUI и не хочет тратить вечер на сборку окружения.

## Что нужно

Linux с одной NVIDIA GPU от **12 ГБ VRAM** (RTX 3060 12 ГБ, RTX 4070 Ti, RTX 3090, RTX 4090, A6000, A100, H100 — все подходят) и актуальный CUDA-драйвер. RealVisXL V5.0 (SDXL, fp16) умещается в 12 ГБ и генерирует изображение `832×1216` за ~30 шагов сэмплинга (DPM++ 2M Karras, CFG 5).

## Запуск

```bash
git clone https://github.com/cloudcompute-ru/comfyui-sdxl.git
cd comfyui-sdxl
bash provision.sh
```

После сообщения `provisioning complete` откройте `http://<host>:8188/` в браузере. Стартовый workflow `sdxl-portrait` доступен в меню **Workflows** — впишите промпт в зелёную ноду **CLIP Text Encode** и нажмите **Queue Prompt**.

`provision.sh` идемпотентен: если веса модели уже скачаны, повторный запуск пропускает этот шаг.

## Что внутри

- `provision.sh` — ставит ComfyUI + ComfyUI Manager, скачивает fp16-чекпоинт RealVisXL V5.0, поднимает сервер на `0.0.0.0:8188`.
- `workflow.json` — стартовый ComfyUI workflow: Load Checkpoint → 2× CLIP Text Encode → Empty Latent 832×1216 → KSampler (30 шагов, CFG 5, DPM++ 2M Karras) → VAE Decode → Save Image.
- `screenshots/` — примеры результатов и скриншоты интерфейса.

## Про cloudcompute.ru

Этот репозиторий поддерживает [cloudcompute.ru](https://cloudcompute.ru) — российский GPU-хостинг с почасовой оплатой. Если не хочется самостоятельно арендовать видеокарту и поднимать контейнер, [cloudcompute.ru/tutorials/comfyui-sdxl](https://cloudcompute.ru/tutorials/comfyui-sdxl) — это тот же скрипт, запущенный в один клик: подбор подходящей видеокарты, оплата по факту работы (от ~45 ₽/час), готовый ComfyUI в браузере через несколько минут. Без локальной установки и без загрузки весов на свой диск.

## Лицензии

Скрипты и конфигурация — MIT (см. `LICENSE`). Модель RealVisXL V5.0 распространяется под лицензией **CreativeML Open RAIL++-M** (см. карточку модели на HuggingFace) — проверьте условия перед коммерческим использованием. ComfyUI — GPL-3.0, ComfyUI Manager — GPL-3.0. Этот репозиторий устанавливает их в runtime, но не модифицирует и не перераспространяет.
