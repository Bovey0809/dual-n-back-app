# Dual N-Back Training App

A cognitive training application designed to improve working memory and fluid intelligence through dual n-back exercises.

## What is Dual N-Back Training?

Dual n-back is a scientifically-backed cognitive training exercise that simultaneously challenges two types of working memory:

- **Spatial Memory**: Remembering the positions of visual stimuli on a 3×3 grid
- **Auditory Memory**: Remembering sequences of spoken letters

The "n" in n-back refers to how many steps back you need to remember. For example, in 2-back, you compare the current stimulus with the one that appeared 2 steps ago.

## Why It Works

### Scientific Background

Research has shown that dual n-back training can:

- **Improve Working Memory**: Enhances your brain's ability to hold and manipulate information
- **Increase Fluid Intelligence**: Improves problem-solving and reasoning abilities
- **Enhance Cognitive Control**: Strengthens attention and executive function
- **Neuroplasticity**: Promotes positive brain changes in areas associated with intelligence

The dual nature of the task (visual + auditory) provides more comprehensive cognitive training than single-modality exercises.

### Key Principles

- **Progressive Overload**: Difficulty automatically adjusts based on performance
- **Dual-Task Training**: Exercises both spatial and auditory working memory simultaneously  
- **Sustained Practice**: Regular training sessions provide cumulative benefits
- **Immediate Feedback**: Real-time audio feedback reinforces learning

## Installation & Setup

### Prerequisites

- Node.js (version 14 or higher)
- npm (comes with Node.js)

### Install Dependencies

```bash
npm install
```

### Run the Application

```bash
npm start
```

This will launch the Electron app in a desktop window.

### Build for Distribution

```bash
# Build for macOS
npm run build

# Create distributable package
npm run dist
```

## How to Use

### Getting Started

1. **Launch the app** using `npm start`
2. **Test audio** using the "Test Audio" button to ensure sound is working
3. **Configure settings** (optional):
   - **N-Level**: Choose difficulty (1-back to 12-back, default: 2-back)
   - **Speed**: Adjust stimulus timing (1.5s to 3s intervals, default: 2.5s)  
   - **Session**: Set training duration (5-30 minutes, default: 20 minutes)
   - **Auto Level**: Enable/disable automatic difficulty adjustment
4. **Click "Start Game"** to begin training

### During Training

#### Visual Component
- Watch for colored squares appearing on the 3×3 grid
- Remember their positions across the sequence

#### Audio Component  
- Listen for letters being spoken (C, H, K, L, Q, R, S, T)
- Remember the sequence of letters

#### Making Responses
- **Position Match (A key)**: Press when the current visual position matches the one from n-steps back
- **Audio Match (L key)**: Press when the current letter matches the one from n-steps back
- **Both matches can occur simultaneously** - respond to each independently

### Controls

| Key | Action |
|-----|--------|
| `A` | Report visual position match |
| `L` | Report audio letter match |
| `Space` | Start/Stop game |

### Audio Feedback

The app provides immediate audio feedback:
- **High chime**: Correct response
- **Low buzz**: Incorrect response  
- **Double beep**: Response made too early (wait for n-back rounds)
- **Soft tone**: Response made when game isn't running

### Auto-Leveling System

When enabled, the system automatically adjusts difficulty:
- **Level Up**: When accuracy ≥ 80% (moves to higher n-back)
- **Level Down**: When accuracy < 60% (moves to lower n-back)
- Requires minimum of 15 trials before level changes
- Helps maintain optimal challenge level

## Features

### Core Training
- **Dual n-back exercise** with visual and auditory components
- **Adjustable difficulty** from 1-back to 12-back
- **Variable speed settings** to control challenge level
- **Session timer** with progress tracking

### Performance Tracking
- **Real-time accuracy** for visual, audio, and combined performance
- **Training records** automatically saved with:
  - Date and duration of sessions
  - N-level and accuracy achieved
  - Speed and auto-level settings
- **Records management** with ability to clear history

### User Experience
- **Modern, intuitive interface** with glassmorphism design
- **Immediate audio feedback** for all responses
- **Visual animations** for button presses and state changes
- **Automatic level adjustment** to maintain optimal difficulty
- **Keyboard shortcuts** for efficient training

### Technical Features
- **Web Audio API** for precise audio timing and feedback
- **Local storage** for persistent training records
- **Single instance** prevention (only one app instance can run)
- **Cross-platform** compatibility (Windows, macOS, Linux)

## Training Tips

### For Beginners
- Start with **2-back** difficulty
- Use **slower speed** (3s) initially
- Focus on **one modality at a time** until comfortable
- Practice **regular short sessions** (10-15 minutes)

### For Advanced Users
- Gradually increase **n-level** as accuracy improves
- Use **faster speeds** to increase challenge
- Aim for **longer sessions** (20-30 minutes)
- Enable **auto-leveling** for optimal progression

### General Guidelines
- **Consistency** is more important than long sessions
- **Expect initial difficulty** - this is normal and beneficial
- **Track progress** using the records system
- **Take breaks** if experiencing fatigue

## Development

### Project Structure

```
dual-n-back-app/
├── main.js          # Electron main process
├── index.html       # Application UI and game logic
├── package.json     # Dependencies and scripts
└── README.md        # This documentation
```

### Key Technologies
- **Electron**: Desktop application framework
- **Web Audio API**: Audio synthesis and playback
- **Local Storage**: Training records persistence
- **CSS3**: Modern UI with animations and effects

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is open source. Feel free to use, modify, and distribute according to your needs.

## Support

If you encounter issues:
1. Ensure your browser/system supports Web Audio API
2. Check that audio is enabled and working
3. Try refreshing or restarting the application
4. Check the console for error messages

For optimal performance, use a modern browser or the Electron desktop version.