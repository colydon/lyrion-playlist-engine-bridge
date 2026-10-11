#!/usr/bin/env python3
"""Meet de werkelijke mix per playlist.

Vraagt via de engine-API steeds één nummer op (precies wat de engine per keer
doet bij het bijvullen) en telt in welke waarderingspool die trekking valt.
Zo zie je of de mix in de praktijk klopt met het ontwerp in
WAARDERING_POOLS.md.

Gebruik (op de Pi):

    python3 rating_mix_report.py                 # 15 trekkingen per playlist
    python3 rating_mix_report.py --samples 40    # nauwkeuriger, duurt langer

Opties:
    --config    pad naar playlist_engine_config.json
    --base-url  basis-URL van de engine (standaard uit het configbestand/ 127.0.0.1:8787)
    --player    spelernaam voor de preview (standaard Kantoor)
    --samples   aantal trekkingen per playlist (standaard 15)
    --playlists alleen deze playlists (komma-gescheiden)
"""
from __future__ import annotations

import argparse
import collections
import json
import urllib.request

TIERS = ['5.0', '4.5', '4.0', '3.5', '3.0', '2.5', '2.0', '<2']
POOL_NAAM = {
    '5.0': 'hits, allerhoogste',
    '4.5': 'hits',
    '4.0': 'hits',
    '3.5': 'ex-hits',
    '3.0': 'best of the rest',
    '2.5': 'oldies/rustig',
    '2.0': 'verrassing',
    '<2': 'onbeoordeeld',
}


def tier(rating: int) -> str:
    if rating >= 100:
        return '5.0'
    if rating >= 90:
        return '4.5'
    if rating >= 80:
        return '4.0'
    if rating >= 70:
        return '3.5'
    if rating >= 60:
        return '3.0'
    if rating >= 50:
        return '2.5'
    if rating >= 40:
        return '2.0'
    return '<2'


def main() -> int:
    parser = argparse.ArgumentParser(description='Meet de mix per playlist via de engine-API.')
    parser.add_argument('--config', default='/home/tc/playlist_engine/playlist_engine_config.json')
    parser.add_argument('--base-url', default='')
    parser.add_argument('--player', default='Kantoor')
    parser.add_argument('--samples', type=int, default=15)
    parser.add_argument('--playlists', default='')
    args = parser.parse_args()

    cfg = json.load(open(args.config, encoding='utf-8'))
    token = cfg.get('api', {}).get('token', '')
    basis = args.base_url or 'http://127.0.0.1:8787'

    namen = [n.strip() for n in args.playlists.split(',') if n.strip()] or list(cfg['playlists'])

    print(f'{args.samples} trekkingen per playlist, speler {args.player}\n')
    print(f"{'playlist':<20} " + ' '.join(f'{t:>6}' for t in TIERS[:-1]))

    for naam in namen:
        per = collections.Counter()
        fouten = 0
        for _ in range(args.samples):
            url = f'{basis}/api/preview?playlist={naam}&player_name={args.player}&count=1'
            vraag = urllib.request.Request(url, headers={'X-API-Key': token})
            try:
                with urllib.request.urlopen(vraag, timeout=60) as antwoord:
                    data = json.load(antwoord)
            except Exception:
                fouten += 1
                continue
            tracks = data.get('tracks') or []
            if tracks:
                per[tier(int(tracks[0].get('rating', 0)))] += 1

        totaal = sum(per.values())
        if not totaal:
            print(f'{naam:<20} geen resultaten (fouten: {fouten})')
            continue

        vakken = ' '.join(f'{100 * per[t] / totaal:>5.1f}%' for t in TIERS[:-1])
        extra = f'  (fouten: {fouten})' if fouten else ''
        print(f'{naam:<20} {vakken}{extra}')

    print('\nKolommen zijn sterren: 5.0 = 5 sterren enzovoort. Verwacht beeld staat in WAARDERING_POOLS.md.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
