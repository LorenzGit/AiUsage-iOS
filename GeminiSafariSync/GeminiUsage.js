function readGeminiUsage() {
    class GeminiUsageReader {
        read() {
            const { origin, pathname } = window.location;
            if (origin !== "https://gemini.google.com" || !/^\/(?:u\/\d+\/)?usage\/?$/.test(pathname)) {
                return null;
            }

            const text = this.usageText();
            const current = text.match(/\bcurrent usage\b/i);
            const weekly = text.match(/\bweekly limit\b/i);
            if (!current || !weekly || weekly.index <= current.index) {
                return null;
            }

            const now = new Date();
            const session = this.parseWindow(text.slice(current.index + current[0].length, weekly.index), now);
            const week = this.parseWindow(text.slice(weekly.index + weekly[0].length), now);
            return session && week ? { outcome: "ready", session, weekly: week } : null;
        }

        usageText() {
            const list = document.querySelector('[aria-label="Usage windows"]');
            if (list?.innerText) return list.innerText.replace(/\s+/g, " ");

            const heading = Array.from(document.querySelectorAll("h1, [role=heading]"))
                .find(element => element.innerText?.trim().toLowerCase() === "usage limits");
            for (let section = heading?.parentElement; section && section !== document.body; section = section.parentElement) {
                const text = section.innerText?.replace(/\s+/g, " ") ?? "";
                if (/\bcurrent usage\b.*\bweekly limit\b/i.test(text)) return text;
            }
            return "";
        }

        parseWindow(text, now) {
            const match = text.match(/\b(\d{1,3}(?:[.,]\d+)?)\s*%\s*used\b/i);
            if (!match) return null;
            const usedPercent = Number(match[1].replace(",", "."));
            if (usedPercent < 0 || usedPercent > 100) return null;

            const resetsAt = this.parseResetTime(text, now);
            return resetsAt === null ? { usedPercent } : { usedPercent, resetsAt };
        }

        parseResetTime(text, now) {
            const reset = text.match(
                /\bresets\s+(?:(?:on\s+)?([a-z]{3,9})\s+(\d{1,2})(?:,\s*(\d{4}))?\s+)?(?:at\s+)?(\d{1,2}):(\d{2})(?:\s*([ap])\.?m\.?)?/i
            );
            if (!reset) return null;

            const [, monthName, day, year, hourText, minuteText, period] = reset;
            let hour = Number(hourText);
            const minute = Number(minuteText);
            if (period) {
                if (hour < 1 || hour > 12) return null;
                hour = hour % 12 + (period.toLowerCase() === "p" ? 12 : 0);
            }
            if (hour > 23 || minute > 59) return null;

            if (monthName) {
                const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
                const month = months.indexOf(monthName.slice(0, 3).toLowerCase());
                if (month < 0) return null;
                return this.nearestDate(
                    (year ? [Number(year)] : [now.getFullYear() - 1, now.getFullYear(), now.getFullYear() + 1])
                        .map(candidate => new Date(candidate, month, Number(day), hour, minute))
                        .filter(date => date.getMonth() === month && date.getDate() === Number(day)),
                    now, 8 * 24
                );
            }

            return this.nearestDate(
                [-1, 0, 1].map(offset => new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset, hour, minute)),
                now, 6
            );
        }

        nearestDate(candidates, now, maxHours) {
            const distance = date => Math.abs(date - now);
            const nearest = candidates.sort((left, right) => distance(left) - distance(right))[0];
            return nearest && distance(nearest) <= maxHours * 3600000 ? nearest.getTime() / 1000 : null;
        }
    }

    return new GeminiUsageReader().read();
}
