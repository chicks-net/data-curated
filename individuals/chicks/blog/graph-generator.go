package main

import (
	"encoding/csv"
	"fmt"
	"log"
	"math"
	"os"
	"strconv"
	"strings"
	"time"
)

type DataPoint struct {
	Month string
	Count int
	Date  time.Time
}

func main() {
	if len(os.Args) < 2 {
		log.Fatal("Usage: go run graph-generator.go <csv-file>")
	}

	csvFile := os.Args[1]
	data, err := readCSV(csvFile)
	if err != nil {
		log.Fatalf("Error reading CSV: %v", err)
	}

	if len(data) == 0 {
		log.Fatal("No data found in CSV")
	}

	// Generate output filename
	outputFile := strings.TrimSuffix(csvFile, ".csv") + "-graph.svg"

	svg := generateSVG(data)
	if err := os.WriteFile(outputFile, []byte(svg), 0644); err != nil {
		log.Fatalf("Error writing SVG: %v", err)
	}

	fmt.Printf("Graph generated: %s\n", outputFile)
}

func readCSV(filename string) ([]DataPoint, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	reader := csv.NewReader(file)
	records, err := reader.ReadAll()
	if err != nil {
		return nil, err
	}

	var data []DataPoint
	for i, record := range records {
		if i == 0 {
			continue // Skip header
		}
		if len(record) < 2 {
			continue
		}

		count, err := strconv.Atoi(record[1])
		if err != nil {
			log.Printf("Warning: invalid count for %s: %v", record[0], err)
			continue
		}

		date, err := time.Parse("2006-01", record[0])
		if err != nil {
			log.Printf("Warning: invalid date %s: %v", record[0], err)
			continue
		}

		data = append(data, DataPoint{
			Month: record[0],
			Count: count,
			Date:  date,
		})
	}

	return data, nil
}

func generateSVG(data []DataPoint) string {
	width := 1200
	height := 420
	padding := 80
	chartWidth := width - padding - 30
	chartHeight := height - padding - 70
	chartTop := 80
	chartLeft := padding

	// Find max count for scaling
	maxCount := 0
	for _, d := range data {
		if d.Count > maxCount {
			maxCount = d.Count
		}
	}

	// Calculate nice y-axis max
	yMax := int(math.Ceil(float64(maxCount)/5) * 5)
	if yMax == 0 {
		yMax = 5
	}

	// Generate path data and points
	pathData := ""
	points := ""

	for i, d := range data {
		x := chartLeft + (i * chartWidth / (len(data) - 1))
		y := chartTop + chartHeight - (d.Count * chartHeight / yMax)

		if i == 0 {
			pathData = fmt.Sprintf("M%d,%d", x, y)
		} else {
			pathData += fmt.Sprintf("L%d,%d", x, y)
		}

		points += fmt.Sprintf(`<line x1="%d" y1="%d" x2="%d" y2="%d" class="ct-point" ct:value="%d"></line>`,
			x, y, x+1, y, d.Count)
	}

	// Generate grid lines
	gridLines := ""

	// Vertical grid lines (y-axis)
	for i := 0; i <= 5; i++ {
		y := chartTop + (i * chartHeight / 5)
		gridLines += fmt.Sprintf(`<line y1="%d" y2="%d" x1="%d" x2="%d" class="ct-grid ct-vertical"></line>`,
			y, y, chartLeft, chartLeft+chartWidth)
	}

	// Horizontal grid lines (x-axis) - every few months
	step := max(1, len(data)/20)
	for i := 0; i < len(data); i += step {
		x := chartLeft + (i * chartWidth / (len(data) - 1))
		gridLines += fmt.Sprintf(`<line x1="%d" x2="%d" y1="%d" y2="%d" class="ct-grid ct-horizontal"></line>`,
			x, x, chartTop, chartTop+chartHeight)
	}

	// Generate labels
	labels := ""

	// X-axis labels (months) - show every Nth month
	labelStep := max(1, len(data)/12)
	for i := 0; i < len(data); i += labelStep {
		d := data[i]
		x := chartLeft + (i * chartWidth / (len(data) - 1))
		y := chartTop + chartHeight + 20

		// Format as "MMM 'YY"
		label := d.Date.Format("Jan '06")
		labels += fmt.Sprintf(`<text x="%d" y="%d" width="60" height="40" class="ct-label ct-horizontal ct-end">%s</text>`,
			x-30, y, label)
	}

	// Y-axis labels
	for i := 0; i <= 5; i++ {
		value := yMax - (i * yMax / 5)
		y := chartTop + (i * chartHeight / 5) + 5
		labels += fmt.Sprintf(`<text y="%d" x="%d" height="20" width="60" class="ct-label ct-vertical ct-start">%d</text>`,
			y, chartLeft-10, value)
	}

	// Build complete SVG
	svg := fmt.Sprintf(`
<svg
    width="%d"
    height="%d"
    viewBox="0 0 %d %d"
    fill="none"
    xmlns="http://www.w3.org/2000/svg">
        <rect xmlns="http://www.w3.org/2000/svg" data-testid="card_bg" id="cardBg"
        x="0" y="0" rx="0" height="100%%" stroke="#E4E2E2" fill-opacity="1"
        width="100%%" fill="#00000000" stroke-opacity="1" style="stroke:#8b949e; stroke-width:1;"/>

        <style>
            body {
                font: 600 18px 'Segoe UI', Ubuntu, Sans-Serif;
            }
            .header {
                font: 600 20px 'Segoe UI', Ubuntu, Sans-Serif;
                text-align: center;
                color: #8b949e;
                margin-top: 20px;
            }
            svg {
                font: 600 18px 'Segoe UI', Ubuntu, Sans-Serif;
                user-select: none;
            }

.ct-label {
  fill: #8b949e;
  color: #8b949e;
  font-size: .75rem;
  line-height: 1;
}

.ct-grid-background,
.ct-line {
  fill: none;
}

.ct-chart-bar .ct-label,
.ct-chart-line .ct-label {
  display: block;
  display: -webkit-box;
  display: -moz-box;
  display: -ms-flexbox;
  display: -webkit-flex;
  display: flex;
}

.ct-label.ct-horizontal.ct-start {
  -webkit-box-align: flex-end;
  -webkit-align-items: flex-end;
  -ms-flex-align: flex-end;
  align-items: flex-end;
  -webkit-box-pack: flex-start;
  -webkit-justify-content: flex-start;
  -ms-flex-pack: flex-start;
  justify-content: flex-start;
  text-align: left;
  text-anchor: start;
}

.ct-label.ct-horizontal.ct-end {
  -webkit-box-align: flex-start;
  -webkit-align-items: flex-start;
  -ms-flex-align: flex-start;
  align-items: flex-start;
  -webkit-box-pack: flex-start;
  -webkit-justify-content: flex-start;
  -ms-flex-pack: flex-start;
  justify-content: flex-start;
  text-align: left;
  text-anchor: start;
}

.ct-label.ct-vertical.ct-start {
  -webkit-box-align: flex-end;
  -webkit-align-items: flex-end;
  -ms-flex-align: flex-end;
  align-items: flex-end;
  -webkit-box-pack: flex-end;
  -webkit-justify-content: flex-end;
  -ms-flex-pack: flex-end;
  justify-content: flex-end;
  text-align: right;
  text-anchor: end;
}

.ct-label.ct-vertical.ct-end {
  -webkit-box-align: flex-end;
  -webkit-align-items: flex-end;
  -ms-flex-align: flex-end;
  align-items: flex-end;
  -webkit-box-pack: flex-start;
  -webkit-justify-content: flex-start;
  -ms-flex-pack: flex-start;
  justify-content: flex-start;
  text-align: left;
  text-anchor: start;
}

.ct-grid {
  stroke: #8b949e;
  stroke-width: 1px;
  stroke-opacity: 0.3;
  stroke-dasharray: 2px;
}

.ct-point {
  stroke-width: 10px;
  stroke-linecap: round;
  stroke: #8b949e;
  animation: blink 1s ease-in-out forwards;
}

.ct-line {
  stroke-width: 4px;
  stroke-dasharray: 5000;
  stroke-dashoffset: 5000;
  stroke: #26a641;
  animation: dash 5s ease-in-out forwards;
}

.ct-area {
  stroke: none;
  fill-opacity: 0.1;
}

.ct-series-a .ct-area,
.ct-series-a .ct-slice-pie {
  fill: #26a641;
}

.ct-label .ct-horizontal {
  transform: rotate(-90deg)
}


    @keyframes blink {
        from {
            opacity: 0;
            transform:translateX(-20px);
        }
        to {
            opacity:1;
            transform: translateX(0);
        }
    }


    @keyframes dash {
        to {
            stroke-dashoffset: 0;
        }
    }


        </style>

        <foreignObject x="0" y="0" width="%d" height="50">
            <h1 xmlns="http://www.w3.org/1999/xhtml" class="header">
                Blog Posts Per Month
            </h1>
        </foreignObject>
        <svg xmlns:ct="http://gionkunz.github.com/chartist-js/ct" width="%d" height="%d" class="ct-chart-line">
            <g class="ct-grids">%s</g>
            <g>
                <g class="ct-series ct-series-a">
                    <path d="%s" class="ct-line"></path>
                    %s
                </g>
            </g>
            <g class="ct-labels">%s</g>
            <text class="ct-axis-title ct-label" x="%d" y="%d" dominant-baseline="text-after-edge" text-anchor="middle">Months</text>
            <text class="ct-axis-title ct-label" x="20" y="%d" transform="rotate(-90, 20, %d)" dominant-baseline="hanging" text-anchor="middle">Posts</text>
        </svg>
</svg>
`, width, height, width, height, width, width, height, gridLines, pathData, points, labels,
		width/2, height-10, height/2, height/2)

	return svg
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
