# SnookFi Smart Contracts

SnookFi is a mobile-first decentralized competitive gaming platform for cue sports, designed to bring transparent matchmaking, skill-based competition, player-owned digital assets, and sustainable reward systems into competitive gaming.

The protocol combines on-chain infrastructure with real-time gameplay systems to create a scalable skill-to-earn gaming ecosystem.

---

# Core Architecture

The SnookFi ecosystem is composed of multiple integrated systems designed to power competitive gameplay, tournaments, and digital asset ownership.

## Match System

A real-time competitive 1v1 matchmaking system designed for transparent and skill-based gameplay.

# Features
- Stake-based matchmaking
- On-chain match creation
- Escrow-secured competitive matches
- Transparent settlement architecture
- Real-time gameplay integration

---

## Tournament Systems

Structured tournament infrastructure supporting multiple competitive formats and scalable progression systems.

### Supported Formats
- Competitive elimination tournaments
- Multi-stage bracket systems
- Seasonal and ranked events
- Community-driven competitive modes

---

## Player Asset Economy

A digital asset layer enabling ownership, trading, and utility of in-game player assets across the SnookFi ecosystem.

### Supported Assets
- Cue assets
- Player avatars
- Cosmetic customizations
- Competitive collectibles
- Tournament-related digital assets

---

# MATCH SYSTEM (`Match.sol`)

## Overview

The Match system powers transparent peer-to-peer competitive gameplay through decentralized matchmaking infrastructure.

Players enter matchmaking queues based on competitive parameters and are automatically paired into live matches.

---

## Match Flow

1. Player joins matchmaking queue
2. Queue system matches eligible players
3. Match instance is created on-chain
4. Gameplay begins in real time
5. Match result is verified
6. Rewards are distributed transparently

---

## Core Features

- Transparent matchmaking logic
- Deterministic queue handling
- Escrow-secured gameplay
- Automated match creation
- Competitive reward settlement
- Non-custodial player infrastructure

---

## Match Lifecycle

- Queue Phase
- Active Match
- Settlement Phase
- Completion

---

# TOURNAMENT SYSTEMS

## Crown Tournament (`CrownTournament.sol`)

A structured competitive tournament system designed for elimination-style gameplay progression.

### Features
- Multi-player tournament brackets
- Automated progression logic
- Transparent settlement architecture
- Competitive reward distribution

---

## Dual Crown Tournament (`DualCrownTournament.sol`)

An advanced tournament structure supporting larger competitive participation and multi-winner settlement systems.

### Features
- Multi-stage progression
- Scalable tournament architecture
- Ranked reward distribution
- High-concurrency competitive support

---

# NFT MARKETPLACE (`SnookFiMarketplace.sol`)

## Overview

The SnookFi Marketplace powers the digital asset economy of the ecosystem, enabling ownership, trading, and utility of player assets within the platform.

The marketplace is designed to support a sustainable player-driven economy integrated directly into competitive gameplay.

---

## Marketplace Features

### Asset Trading

Players can trade supported digital assets within the ecosystem through decentralized marketplace infrastructure.

###  Asset Rentals

Supported player assets can be temporarily rented for gameplay and tournament participation.

### Cosmetic Customization

Players can personalize gameplay identity and visual representation using collectible cosmetic assets.

### Competitive Utility

Certain player assets may provide ecosystem utility tied to progression, competitive participation, and digital identity.

---

## Marketplace Design Principles

- Player-owned digital assets
- Non-custodial ownership
- Secure transaction settlement
- Integrated gameplay utility
- Sustainable ecosystem participation

---

# Security Architecture

SnookFi is designed with a security-first infrastructure approach focused on competitive integrity and transparent settlement systems.

## Security Principles

- Non-custodial asset ownership
- Escrow-secured settlement systems
- Controlled verification architecture
- Immutable match records
- Secure gameplay settlement flows

---

## Competitive Integrity

The platform uses a hybrid verification architecture where gameplay telemetry and competitive activity are validated through secure verification systems before settlement execution.

This architecture is designed to:
- improve competitive fairness
- reduce fraudulent reporting
- support scalable multiplayer infrastructure
- enhance long-term ecosystem integrity

---

# Core Design Principles

SnookFi is built around the following principles:

- Transparent competitive infrastructure
- Skill-based gameplay systems
- Sustainable ecosystem design
- Player-owned digital economies
- Scalable matchmaking architecture
- Mobile-first accessibility
- Competitive integrity

---

# Protocol Events

Examples of ecosystem events emitted by the protocol include:

- `PlayerQueued`
- `MatchCreated`
- `TournamentJoined`
- `ItemListed`
- `ItemSold`

---

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
