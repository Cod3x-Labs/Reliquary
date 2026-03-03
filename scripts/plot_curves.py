#!/usr/bin/env python3
"""Parse curves.log and generate 3 charts: Multiplier, Pending USDC, Accumulated Balance."""

import re
import os
from collections import defaultdict

import matplotlib.pyplot as plt

LOG_FILE = os.path.join(os.path.dirname(__file__), "..", "curves.log")
OUTPUT_FILE = os.path.join(os.path.dirname(__file__), "..", "curves_charts.png")

USERS = ["Main user", "User1", "User2", "User3"]
COLORS = {"Main user": "#2563eb", "User1": "#dc2626", "User2": "#16a34a", "User3": "#f59e0b"}
INITIAL_BALANCE = {"Main user": 7.5, "User1": 0.0, "User2": 0.0, "User3": 0.0}

# Regex patterns
pending_re = re.compile(r"^\s*(Main user|User[123]) Day (\d+)\. Pending USDC: ([\d.]+)")
multiplier_re = re.compile(r"^\s*(Main user|User[123]) multiplier:\s+(\d+)")


def parse_log(path):
    days = defaultdict(dict)           # {user: {day: pending_usdc}}
    multipliers = defaultdict(dict)    # {user: {day: multiplier}}

    current_day = {}  # last seen day per user (for matching multiplier lines)

    with open(path) as f:
        for line in f:
            m = pending_re.match(line)
            if m:
                user, day, pending = m.group(1), int(m.group(2)), float(m.group(3))
                days[user][day] = pending
                current_day[user] = day
                continue

            m = multiplier_re.match(line)
            if m:
                user, mult = m.group(1), int(m.group(2))
                day = current_day.get(user)
                if day is not None:
                    multipliers[user][day] = mult

    return days, multipliers


def build_series(days, multipliers):
    """Return sorted arrays for each user."""
    result = {}
    for user in USERS:
        sorted_days = sorted(days.get(user, {}).keys())
        pending = [days[user][d] for d in sorted_days]
        mults = [multipliers.get(user, {}).get(d, 10000) for d in sorted_days]

        # Accumulated balance = initial + running sum of pending
        acc = []
        running = INITIAL_BALANCE[user]
        for p in pending:
            running += p
            acc.append(running)

        result[user] = {
            "days": sorted_days,
            "pending": pending,
            "multiplier": [m / 10000.0 for m in mults],  # normalize (1.0 = base)
            "balance": acc,
        }
    return result


def plot(series, output):
    fig, axes = plt.subplots(3, 1, figsize=(14, 16), sharex=True)
    fig.suptitle("Reliquary Staking Simulation — 1 Year Polynomial Curve", fontsize=15, fontweight="bold")

    # --- Chart 1: Multiplier over Time ---
    ax = axes[0]
    for user in USERS:
        s = series[user]
        ax.plot(s["days"], s["multiplier"], label=user, color=COLORS[user], linewidth=1.8)
    ax.set_ylabel("Multiplier (x)")
    ax.set_title("Multiplier over Time")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    # --- Chart 2: Pending USDC (Rewards) over Time ---
    ax = axes[1]
    for user in USERS:
        s = series[user]
        ax.plot(s["days"], s["pending"], label=user, color=COLORS[user], linewidth=1.8)
    ax.set_ylabel("Pending USDC")
    ax.set_title("Pending USDC (Rewards) over Time")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    # --- Chart 3: User Balance (Accumulated, USDC Adjusted) ---
    ax = axes[2]
    for user in USERS:
        s = series[user]
        ax.plot(s["days"], s["balance"], label=user, color=COLORS[user], linewidth=1.8)
    ax.set_xlabel("Day")
    ax.set_ylabel("Accumulated Balance (USDC)")
    ax.set_title("User Balance (Accumulated, USDC Adjusted)")
    ax.legend(loc="upper left")
    ax.grid(True, alpha=0.3)

    plt.tight_layout(rect=[0, 0, 1, 0.96])
    plt.savefig(output, dpi=150)
    print(f"Chart saved to {output}")
    plt.show()


if __name__ == "__main__":
    days, multipliers = parse_log(LOG_FILE)
    series = build_series(days, multipliers)

    for user in USERS:
        s = series[user]
        print(f"{user}: {len(s['days'])} data points, "
              f"final multiplier={s['multiplier'][-1]:.4f}x, "
              f"final balance={s['balance'][-1]:.2f} USDC")

    plot(series, OUTPUT_FILE)
